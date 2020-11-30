module Simp; end

module Simp::SimpCoreDepsHelper

  # @return the changelog difference between the version of a component checked
  #   out in component_dir and prev_version
  def changelog_diff(component_dir, prev_version)
    diff = nil
    Dir.chdir(component_dir) do
      if File.exist?('CHANGELOG')
        if prev_version
          cmd = "git diff #{prev_version} CHANGELOG"
        else
          cmd = 'cat CHANGELOG'
        end
        diff = `#{cmd}`
      elsif Dir.exist?('build')
        spec_files = Dir.glob('build/*.spec')
        unless spec_files.empty?
          spec_file = spec_files.first
          if prev_version
            cmd = "git diff #{prev_version} #{spec_file}"
          else
            cmd = "cat #{spec_file}"
          end
          specfile_diff = `#{cmd}`
          # only want changelog changes in spec file
          diff = specfile_diff.split('%changelog').last
        end
      end
    end

    if diff.nil?
      diff = "WARNING: Could not find CHANGELOG or RPM spec file in #{component_dir}"
    end

    diff
  end

  # @return String containing component changelog differences and git log
  #   entries since the previous tag
  def component_changes(component_dir, current_tag, prev_tag, log_args, debug)
    changelog_diff_output = changelog_diff(component_dir, prev_version)

    Dir.chdir(component_dir) do
          if prev_version
            log_cmd = "git log #{prev_version}..HEAD #{log_args}"
          else
            log_cmd = "git log #{log_args}"
          end

          puts "In #{File.basename(Dir.pwd)} executing: #{log_cmd}" if debug
          log_output = %x(#{log_cmd})
        end

        # TODO figure out if desired_ref is the correct key when a branch is specified
        unless current_tag == prev_version
          output = [
            "Current version: #{mod[:desired_ref]}   Previous version: #{prev_version.nil? ? 'N/A' : prev_version}",
            'CHANGELOG diff:',
             changelog_diff_output,
            '',
            'Git Log:',
            log_output
          ].join("\n")
          git_logs[mod[:name]] = output
        end

  end

  # @return Hash of component versions from the Puppetfile.<suffix> for the
  #   simp-core tag <tag>
  #
  # @param tag simp-core tag
  # @param suffix Suffix of the Puppetfile to use to gather the component
  #    information
  #
  # @raise if Puppetfile specified is not available
  #
  def component_versions_for_tag(tag, suffix, debug)
    cmd = "git show #{tag}:Puppetfile.#{suffix}"
    puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if debug
    puppetfile = %x(#{cmd})

    if $? and $?.exitstatus != 0
      fail("Puppetfile.#{suffix} not found at #{tag}")
    end

    require 'tmpdir'

    component_versions = {}
    Dir.mktmpdir( File.basename( __FILE__ ) ) do |dir|
      File.open("#{dir}/Puppetfile", 'w') { |file| file.puts(puppetfile) }
      r10k_helper = R10K::Puppetfile.new("#{dir}/Puppetfile")
      r10k_helper.modules.collect do |mod|
        component_versions[mod[:name]] = mod[:desired_ref]
      end
    end

    component_versions
  end

  def simp_component?(component_dir)
    result = false
    metadata_json_file = File.join(component_dir, 'metadata.json')
    if File.exist?(metadata_json_file)
      require 'json'
      metadata = JSON.load(File.read(metadata_json_file))
      if metadata['name'].split('-').first == 'simp'
        result = true
      end
    else
      build_dir = File.join(component_dir, 'build')
      if Dir.exist?(build_dir)
        spec_files = Dir.glob("#{build_dir}/*.spec")
        if spec_files.size == 1
          result = true
        end
      end
    end

    result
  end

  # @return String containing simp.spec changelog differences and simp-core git
  #   log entries since the previous tag
  def simp_core_changes(prev_tag, log_args, debug)
    changelog_diff_output = changelog_diff('src/assets/simp', prev_tag)
    cmd = "git log #{prev_tag}..HEAD #{log_args}"
    puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if debug
    log_output = %x(#{cmd})

    changes = [
      'CHANGELOG diff:',
      changelog_diff_output,
      '',
      'Git Log:',
      log_output
    ].join("\n")

    changes
  end
end
