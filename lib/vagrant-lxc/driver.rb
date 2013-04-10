require "vagrant/util/retryable"
require "vagrant/util/subprocess"

require "vagrant-lxc/errors"
require "vagrant-lxc/driver/cli"

module Vagrant
  module LXC
    class Driver
      # This is raised if the container can't be found when initializing it with
      # a name.
      class ContainerNotFound < StandardError; end

      attr_reader :container_name,
                  :customizations

      def initialize(container_name, cli = CLI.new(container_name))
        @container_name = container_name
        @cli            = cli
        @logger         = Log4r::Logger.new("vagrant::provider::lxc::driver")
        @customizations = []
      end

      def validate!
        raise ContainerNotFound if @container_name && ! @cli.list.include?(@container_name)
      end

      def base_path
        Pathname.new("#{CONTAINERS_PATH}/#{@container_name}")
      end

      def rootfs_path
        Pathname.new(base_path.join('config').read.match(/^lxc\.rootfs\s+=\s+(.+)$/)[1])
      end

      def create(name, template_path, template_options = {})
        @cli.name = @container_name = name

        import_template(template_path) do |template_name|
          @logger.debug "Creating container..."
          @cli.create template_name, template_options
        end
      end

      def share_folders(folders)
        folders.each do |folder|
          guestpath = rootfs_path.join(folder[:guestpath].gsub(/^\//, ''))
          unless guestpath.directory?
            begin
              @logger.debug("Guest path doesn't exist, creating: #{guestpath}")
              system "sudo mkdir -p #{guestpath.to_s}"
            rescue Errno::EACCES
              raise Vagrant::Errors::SharedFolderCreateFailed, :path => guestpath.to_s
            end
          end

          @customizations << ['mount.entry', "#{folder[:hostpath]} #{guestpath} none bind 0 0"]
        end
      end

      def start(customizations)
        @logger.info('Starting container...')

        if ENV['LXC_START_LOG_FILE']
          extra = ['-o', ENV['LXC_START_LOG_FILE'], '-l', 'DEBUG']
        end
        customizations = customizations + @customizations

        @cli.transition_to(:running) { |c| c.start(customizations, (extra || nil)) }
      end

      def halt
        @logger.info('Shutting down container...')

        # TODO: issue an lxc-stop if a timeout gets reached
        @cli.transition_to(:stopped) { |c| c.shutdown }
      end

      def destroy
        @cli.destroy
      end

      # TODO: This needs to be reviewed and specs needs to be written
      def compress_rootfs
        rootfs_dirname = File.dirname rootfs_path
        basename       = rootfs_path.to_s.gsub(/^#{Regexp.escape rootfs_dirname}\//, '')
        # TODO: Pass in tmpdir so we can clean up from outside
        target_path    = "#{Dir.mktmpdir}/rootfs.tar.gz"

        Dir.chdir base_path do
          @logger.info "Compressing '#{rootfs_path}' rootfs to #{target_path}"
          system "sudo rm -f rootfs.tar.gz && sudo tar --numeric-owner -czf #{target_path} #{basename}/*"

          @logger.info "Changing rootfs tarbal owner"
          system "sudo chown #{ENV['USER']}:#{ENV['USER']} #{target_path}"
        end

        target_path
      end

      def state
        if @container_name
          @cli.state
        end
      end

      def assigned_ip
        ip = ''
        retryable(:on => LXC::Errors::ExecuteError, :tries => 10, :sleep => 3) do
          unless ip = get_container_ip_from_ip_addr
            # retry
            raise LXC::Errors::ExecuteError, :command => "lxc-attach"
          end
        end
        ip
      end

      # From: https://github.com/lxc/lxc/blob/staging/src/python-lxc/lxc/__init__.py#L371-L385
      def get_container_ip_from_ip_addr
        output = @cli.attach '/sbin/ip', '-4', 'addr', 'show', 'scope', 'global', 'eth0', namespaces: 'network'
        if output =~ /^\s+inet ([0-9.]+)\/[0-9]+\s+/
          return $1.to_s
        end
      end

      protected

      # Root folder where container configs are stored
      CONTAINERS_PATH = '/var/lib/lxc'

      def base_path
        Pathname.new("#{CONTAINERS_PATH}/#{@container_name}")
      end

      def import_template(path)
        template_name     = "vagrant-tmp-#{@container_name}"
        tmp_template_path = templates_path.join("lxc-#{template_name}").to_s

        @logger.debug 'Copying LXC template into place'
        system(%Q[sudo su root -c "cp #{path} #{tmp_template_path}"])

        yield template_name
      ensure
        system(%Q[sudo su root -c "rm #{tmp_template_path}"])
      end

      TEMPLATES_PATH_LOOKUP = %w(
        /usr/share/lxc/templates
        /usr/lib/lxc/templates
      )
      def templates_path
        return @templates_path if @templates_path

        path = TEMPLATES_PATH_LOOKUP.find { |candidate| File.directory?(candidate) }
        # TODO: Raise an user friendly error
        raise 'Unable to identify lxc templates path!' unless path

        @templates_path = Pathname(path)
      end
    end
  end
end