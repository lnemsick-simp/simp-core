# simp-core additions to dep targets
# This is a playground for tasks that may eventually be moved to simp-rake-helpers
#
require 'pager'
require 'tmpdir'
require 'json'

module Simp ; end

module Simp::ChangelogDiffHelper

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

  def simp_component?(component_dir)
    result = false
    metadata_json_file = File.join(component_dir, 'metadata.json')
    if File.exist?(metadata_json_file)
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
end


include Pager
include Simp::ChangelogDiffHelper


namespace :deps do
  desc <<-EOM
  Remove all checked-out dependency repos

  Uses specified Puppetfile to identify the checked-out repos.

  Arguments:
    * :suffix       => The Puppetfile suffix to use (Default => 'tracking')
    * :remove_cache => Whether to remove the R10K cache after removing the
                       checked-out repos (Default => false)
  EOM
  task :clean, [:suffix,:remove_cache] do |t,args|
    include Pager

    args.with_defaults(:suffix => 'tracking')
    args.with_defaults(:remove_cache => false)
    base_dir = File.dirname(__FILE__)

    r10k_helper = R10KHelper.new("Puppetfile.#{args[:suffix]}")

    r10k_issues = Parallel.map(
      Array(r10k_helper.modules),
        :in_processes => get_cpu_limit,
        :progress => 'Dependency Removal'
    ) do |mod|
      Dir.chdir(base_dir) do
        FileUtils.rm_rf(mod[:path])
      end
    end

    if args[:remove_cache]
      cache_dir = File.join(base_dir, '.r10k_cache')
      FileUtils.rm_rf(cache_dir)
    end
  end


  desc <<-EOM
  EXPERIMENTAL
  Generate a list of git logs for the changes since a previous
  simp-core tag.  Includes
  - simp-core changes
  - Individual module changes.  The changes are from the version
    listed in the tag's Puppetfile to the version specified in the
    current Puppetfile

  ASSUMES you have executed deps:checkout[curr_suffix]

  Arguments:
    * :prev_tag    => simp-core previous version tag
    * :prev_suffix => The Puppetfile suffix to use from the previous simp-core tag;
                      DEFAULT: 'tracking'
    * :curr_suffix => The Puppetfile suffix to use from this simp-core checkout
                      DEFAULT: 'pinned'
    * :brief       => Only show oneline summaries; DEFAULT: false
    * :debug       => Log status gathering actions; DEFAULT: false
  EOM
  task :changes_since, [:prev_tag,:prev_suffix,:curr_suffix,:brief,:debug] do |t,args|
    args.with_defaults(:prev_suffix => 'tracking')
    args.with_defaults(:curr_suffix => 'pinned')
    args.with_defaults(:brief => false)
    args.with_defaults(:debug => false)
    log_args = args[:brief] ? '--oneline' : ''

    old_component_versions = {}
    Dir.mktmpdir( File.basename( __FILE__ ) ) do
      cmd = "git show #{args[:prev_tag]}:Puppetfile.#{args[:prev_suffix]}"
      puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if args[:debug]
      prev_puppetfile = %x(#{cmd})
      File.open('Puppetfile.pre', 'w') { |file| file.puts(prev_puppetfile) }
      r10k_helper_prev = R10KHelper.new('Puppetfile.pre')
      r10k_helper_prev.each_module do |mod|
        old_component_versions[mod[:name]] = mod[:desired_ref]
      end
    end

    git_logs = Hash.new
    cmd = "git log #{args[:prev_tag]}..HEAD --reverse #{log_args}"
    puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if args[:debug]
    log_output = %x(#{cmd})
    git_logs['__SIMP CORE__'] = log_output unless log_output.strip.empty?

    r10k_helper_curr = R10KHelper.new("Puppetfile.#{args[:curr_suffix]}")
    r10k_helper_curr.each_module do |mod|
      if File.directory?(mod[:path])
        next unless simp_component?(mod[:path])
        prev_version = old_component_versions[mod[:name]]
        changelog_diff_output = changelog_diff(mod[:path], prev_version)

        Dir.chdir(mod[:path]) do
          if prev_version
            log_cmd = "git log #{prev_version}..HEAD --reverse #{log_args}"
          else
            log_cmd = "git log --reverse #{log_args}"
          end

          puts "In #{File.basename(Dir.pwd)} executing: #{log_cmd}" if args[:debug]
          log_output = %x(#{log_cmd})
        end

        unless mod[:desired_ref] == prev_version
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
      else
        $stderr.puts "WARNING: #{mod[:path]} not found"
      end
    end

    if git_logs.empty?
      puts( "No changes found for any components since SIMP #{args[:prev_tag]}")
    else
      page

      puts "Comparison with SIMP #{args[:prev_tag]}"
      git_logs.keys.sort.each do |component_name|
        puts <<-EOM
#{'='*80}
#{component_name}:

#{git_logs[component_name].gsub(/^/,'  ')}

        EOM
      end
    end
  end

end
