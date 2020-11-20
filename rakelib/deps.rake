# simp-core additions to dep targets
# This is a playground for tasks that may eventually be moved to simp-rake-helpers
#
require 'pager'
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
    base_dir = Dir.pwd  # assuming at simp-core root dir
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
  Generate a list of changes since a previous simp-core tag.
  Includes:
  - simp-core changes noted in its git logs
  - simp.spec %changelog changes
  - Individual SIMP component changes noted both in its git logs and its
    CHANGELOG file or %changelog section of its build/<component>.spec file.
    - The changes are from the version listed in the tag's Puppetfile
      to the version specified in the current Puppetfile

  ASSUMES:
  - You have executed deps:checkout[curr_suffix].
  - The rake task is being called from the simp-core root directory.

  FAILS:
  - The simp-core tag specified is not available locally.
  - The specified Puppetfile at the simp-core tag is not available.

  Arguments:
    * :prev_tag    => simp-core previous version tag
    * :prev_suffix => The Puppetfile suffix to use from the previous simp-core tag;
                      DEFAULT: 'pinned'
    * :curr_suffix => The Puppetfile suffix to use from this simp-core checkout
                      DEFAULT: 'pinned'
    * :brief       => Only show oneline summaries; DEFAULT: false
    * :debug       => Log status gathering actions; DEFAULT: false
  EOM
  task :changes_since, [:prev_tag,:prev_suffix,:curr_suffix,:brief,:debug] do |t,args|
    args.with_defaults(:prev_suffix => 'pinned')
    args.with_defaults(:curr_suffix => 'pinned')
    args.with_defaults(:brief => 'false')
    args.with_defaults(:debug => 'false')
    log_args = (args[:brief] == 'true') ? '--oneline' : ''
    debug = (args[:debug] == 'true') ? true : false

    # validate arguments
    result = `git tag -l #{args[:prev_tag]}`
    unless result.include?(args[:prev_tag])
      fail("Tag #{args[:prev_tag]} not found")
    end

    cmd = "git show #{args[:prev_tag]}:Puppetfile.#{args[:prev_suffix]}"
    if $? and $?.exitstatus != 0
      fail("Puppetfile.#{args[:prev_suffix]} not found at #{args[:prev_tag]}")
    end

    git_logs = {}
    git_logs['__SIMP CORE__'] = simp_core_changes(args[:prev_tag], log_args, debug)

    old_component_versions = component_versions_for_tag(args[:prev_tag],
      args[:prev_suffix], debug)

    # Gather changes for Puppetfile dependencies
    #TODO invoke deps:checkout with :curr_suffix
    log_output = ''
    r10k_helper = R10KHelper.new("Puppetfile.#{args[:curr_suffix]}")
    r10k_helper.each_module do |mod|
      if File.directory?(mod[:path])
        next unless simp_component?(mod[:path])

        # TODO figure out if desired_ref is the correct key when a branch is specified
        current_version = mod[:desired_ref]
        prev_version = old_component_versions[mod[:name]]
        unless current_version == prev_version
          changes = component_changes(mod[:path], current_version, prev_version,
            log_args, debug)

          git_logs[mod[:name]] = changes
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
        puts <<~EOM
          #{'='*80}
          #{component_name}:

          #{git_logs[component_name].gsub(/^/,'  ')}

        EOM
      end
    end
  end
end
