# simp-core additions to dep targets
# This is a playground for tasks that may eventually be moved to simp-rake-helpers
#
require 'pager'
require 'tmpdir'
require 'json'
require_relative 'simp_core_deps_helper'

include Pager
include Simp::SimpCoreDepsHelper

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

    #TODO invoke deps:checkout with :curr_suffix
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

        # TODO figure out if desired_ref is the correct key when a branch is specified
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

  desc <<-EOM
  Logs the .gitlab-ci.yml coverage for the acceptance test suites, taking
  into consideration nodesets available for the suite and ASSUMING the tests
  should also be run in FIPS-mode.

  Each line contains the following columns separated by a ',':
  - component name (directory name)
  - suite
  - nodeset
  - Puppet version (pulled from the .gitlab-ci.yml)
  - FIPS status (enabled/disabled)
  - GitLab job status:
    - present:       the job is present in .gitlab-ci.yml
    - absent: :      the job is absent from .gitlab-ci.yml
    - misconfigured: the job from .gitlab-ci.yml doesn't match the project

  ASSUMES
  - You have executed deps:checkout[appropriate_suffix]
  - Puppet modules are in src/puppet/modules
  - Assets are in src/assets
  EOM
  task :gitlab_job_coverage, [:debug] do |t,args|
    args.with_defaults(:debug => false)

    test_sets = []
    module_dirs = Dir.glob('src/puppet/modules/*')
    asset_dirs = Dir.glob('src/assets/*').delete_if { |x| File.basename(x) == 'simp' }
    component_dirs = [ '.' ] + module_dirs + asset_dirs
    component_dirs.map! { |dir| File.expand_path(dir) }
    component_dirs.sort_by! { |x| File.basename(x) }
    component_dirs.each do |component_dir|
      next unless simp_component?(component_dir)
      puts "Processing #{File.basename(component_dir)}" if args[:debug]
      puppet_versions, gitlab_tests = get_gitlab_acceptance_test_matrix(component_dir)
      possible_test_sets = get_acceptance_test_matrix(component_dir, puppet_versions)
      if args[:debug]
      end

      possible_test_sets.each do |test_info|
        test_present = gitlab_tests.include?(test_info) ? 'present' : 'absent'

        # if the test suite is NONE, presence is immaterial
        test_present = 'N/A' if test_info[1] == 'NONE'

        test_sets << (test_info + [ test_present ] )
      end

      misconfigured_found = false
      gitlab_tests.each do |test_info|
        unless possible_test_sets.include?(test_info)
          misconfigured_found = true
          test_sets << (test_info + ['misconfigured'])
        end
      end

      if misconfigured_found and args[:debug]
        puts "Misconfiguration detected for #{File.basename(component_dir)}"
        puts "  gitlab tests:"
        gitlab_tests.each { |test_info| puts ' '*4 + test_info.inspect }
        puts "  possible tests:"
        possible_test_sets.each { |test_info| puts' '*4 +  test_info.inspect }
      end
    end

    headings = [
      'Component',
      'Suite',
      'Nodeset',
      'Puppet Version',
      'FIPS',
      'Status'
    ]
    puts headings.join(',')
    test_sets.each do |component_tests|
      component_tests.each do |test|
        puts test.join(',')
      end
    end
  end

end
