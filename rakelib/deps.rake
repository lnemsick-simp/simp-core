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
  Generate a list of changes since a previous simp-core tag.

  Includes:
  - simp-core changes noted in its git logs
  - Individual module changes noted both in its Changelog or
    build/<component>.spec file and its git logs
    - The changes are from the version listed in the tag's Puppetfile
      to the version specified in the current Puppetfile

  ASSUMES you have executed deps:checkout[curr_suffix]

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

    old_component_versions = {}
    Dir.mktmpdir( File.basename( __FILE__ ) ) do
      cmd = "git show #{args[:prev_tag]}:Puppetfile.#{args[:prev_suffix]}"
      puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if debug
      prev_puppetfile = %x(#{cmd})
      File.open('Puppetfile.pre', 'w') { |file| file.puts(prev_puppetfile) }
      r10k_helper_prev = R10KHelper.new('Puppetfile.pre')
      r10k_helper_prev.each_module do |mod|
        old_component_versions[mod[:name]] = mod[:desired_ref]
      end
    end

    # Gather changes for simp-core including simp.spec
    git_logs = Hash.new

    changelog_diff_output = changelog_diff('src/assets/simp', args[:prev_tag])
    cmd = "git log #{args[:prev_tag]}..HEAD --reverse #{log_args}"
    puts "In #{File.basename(Dir.pwd)} executing: #{cmd}" if debug
    log_output = %x(#{cmd})
    output = [
      'CHANGELOG diff:',
      changelog_diff_output,
      '',
      'Git Log:',
      log_output
    ].join("\n")
    git_logs['__SIMP CORE__'] = output

    # Gather changes for Puppetfile dependencies
    #TODO invoke deps:checkout with :curr_suffix
    r10k_helper_curr = R10KHelper.new("Puppetfile.#{args[:curr_suffix]}")
    r10k_helper_curr.each_module do |mod|
      if File.directory?(mod[:path])
        next unless simp_component?(mod[:path])
        prev_version = old_component_versions[mod[:name]]
        changelog_diff_output = changelog_diff(mod[:path], prev_version)

        Dir.chdir(mod[:path]) do
          if prev_version
            log_cmd = "git log #{prev_version}..HEAD #{log_args}"
          else
            log_cmd = "git log #{log_args}"
          end

          puts "In #{File.basename(Dir.pwd)} executing: #{log_cmd}" if debug
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
end
