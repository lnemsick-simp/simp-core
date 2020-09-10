module Simp; end

module Simp::SimpCoreDepsHelper

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

  # @returns array of suites executed along with the default suite when
  # 'bundle exec rake beaker:suites' is called without specifying a suite
  def default_suite_additions(component_dir)
    additions = []
    Dir.chdir(component_dir) do
      suites = Dir.glob('spec/acceptance/suites/*')
      suites.delete_if { |x| (! File.directory?(x)) || (File.basename(x) == 'default') }
      suites.each do |suite_dir|
        test_meta_file = File.join(suite_dir, 'metadata.yml')
        if File.exist?(test_meta_file)
          test_meta = YAML.load(File.read(test_meta_file))
          if test_meta['default_run']
            additions << File.basename(suite_dir)
          end
        end
      end
    end
    additions
  end

  def generate_full_acceptance_matrix(test_info, puppet_versions, include_fips = true)
    component = test_info[:component]
    if test_info[:suites].empty? || puppet_versions.nil? || puppet_versions.empty?
      null_test = {
        :component      => component,
        :suite          => 'NONE',
        :nodeset        => 'N/A',
        :puppet_version => 'N/A',
        :fips           => 'N/A'
      }
      return [ null_test ]
    end
    tests = []
    test_info[:suites].each do |suite, config|
      config[:nodesets].each do |nodeset|
        puppet_versions.each do |puppet_version|
          test = {
            :component      => component,
            :suite          => suite,
            :nodeset        => nodeset,
            :puppet_version => puppet_version,
            :fips           => :disabled
          }
          tests << test
          if include_fips
            fips_test = test.dup
            fips_test[:fips] = :enabled
            tests << fips_test
          end
        end
      end
    end
    tests
  end

  def acceptance_test_info(component_dir)
    test_info = {
      :component => File.basename(component_dir),
      :suites    => {}
    }

    Dir.chdir(component_dir) do
      suites = Dir.glob('spec/acceptance/suites/*')
      suites.delete_if { |x| ! File.directory?(x) }

      global_nodeset_dir = 'spec/acceptance/nodesets'
      suites.each do |suite_dir|
        nodeset_dir = File.join(suite_dir, 'nodesets')
        if Dir.exist?(nodeset_dir)
          all_nodesets = Dir.glob("#{nodeset_dir}/*yml")
        else
          all_nodesets = Dir.glob("#{global_nodeset_dir}/*yml")
        end
        nodesets = all_nodesets.dup
        nodesets.delete_if { |nodeset| File.symlink?(nodeset) }

        suite = File.basename(suite_dir)
        test_info[:suites][suite] = {
          :nodesets => nodesets.map {|nodeset| File.basename(nodeset, '.yml') }
        }

        linked_nodesets = all_nodesets.dup
        linked_nodesets.delete_if { |nodeset| !File.symlink?(nodeset) }

        linked_nodesets.each do |link_path|
          source =  File.basename(File.readlink(link_path), '.yml')
          link = File.basename(link_path, '.yml')

          test_info[:suites][suite][:nodesets].map! do |nodeset|
            if nodeset == source
              "#{link}->#{source}"
            else
              nodeset
            end
          end
        end
      end
    end
    test_info
  end

  # @returns complete set of possible acceptance tests that can be run
  def acceptance_test_matrix(component_dir, puppet_versions)
    test_info = acceptance_test_info(component_dir)
    matrix = generate_full_acceptance_matrix(test_info, puppet_versions, true)
    matrix.sort_by { |test_info| test_info.to_s }
  end

  def gitlab_acceptance_test_matrix(component_dir)
    gitlab_yaml_file = File.join(component_dir, '.gitlab-ci.yml')
    component = File.basename(component_dir)
    null_test = {
      :component      => component,
      :suite          => 'NONE',
      :nodeset        => 'N/A',
      :puppet_version => 'N/A',
      :fips           => 'N/A'
    }

    unless File.exist?(gitlab_yaml_file)
      return [ ['N/A'], [ null_test ] ]
    end

    gitlab_yaml = YAML.load(File.read(gitlab_yaml_file))
    tests = []
    puppet_versions = []
    gitlab_yaml.each do |key,value|
      next unless (value.is_a?(Hash) && value.has_key?('script'))
      next unless (value.has_key?('stage') && (value['stage'] == 'acceptance'))

      if value.has_key?('variables') && value['variables'].has_key?('PUPPET_VERSION')
        puppet_version = value['variables']['PUPPET_VERSION']
      else
        puppet_version = 'N/A'
      end

      suite = nil
      nodeset = nil
      is_global_nodeset = nil
      fips = nil
      value['script'].each do |line|
        next unless line.include? 'beaker:suites'
        if line.include?('[')
          match = line.match(/beaker:suites\[([\w\-_]*)(,([\w\-_]*))?\]/)
          suite = match[1]
          nodeset = match[3]
          if nodeset.nil?
            puts "#{component} job '#{key}' missing nodeset: #{line}"
          end
        else
          puts "#{component} job '#{key}' missing suite and nodeset: #{line}"
          suites = Dir.glob("#{component_dir}/spec/acceptance/suites/*")
          suites.delete_if { |x| ! File.directory?(x) }
          if suites.size > 1
            suite = (['default'] + default_suite_additions(component_dir))
          else
            suite = 'default'
          end
          nodeset = 'default'
        end

        if line.include?('BEAKER_fips=yes')
          fips = :enabled
        else
          fips = :disabled
        end
      end
      next unless suite

      suite.strip! if suite.is_a?(String)
      nodeset = nodeset.nil? ? 'default' : nodeset.strip

      nodeset_yml = "#{component_dir}/spec/acceptance/suites/#{suite}/#{nodeset}.yml"
      unless File.exist?(nodeset_yml)
        nodeset_yml = "#{component_dir}/spec/acceptance/nodesets/#{nodeset}.yml"
      end

      if File.symlink?(nodeset_yml)
        source = File.basename(File.readlink(nodeset_yml), '.yml')
        nodeset = "#{nodeset}->#{source}"
      end

      puppet_versions << puppet_version
      test = {
        :component      => component,
        :suite          => suite,
        :nodeset        => nodeset,
        :puppet_version => puppet_version,
        :fips           => fips
      }
      tests << test
    end
    tests = [ null_test ] if tests.empty?
    [ puppet_versions.uniq!, tests.sort_by { |test_info| test_info.to_s }]
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

  def test_present?(test_info, gitlab_tests)
    status = :absent
    if gitlab_tests.include?(test_info)
      # exact permutation spelled out in a GitLab job
      status = :present
    else
      # test might be bundled with a implied 'default + additions' GitLab job
      # when beaker:suites has no arguments
      gitlab_tests.each do |gitlab_test_info|
        if ( gitlab_test_info[:suite].is_a?(Array) &&
             gitlab_test_info[:suite].include?(test_info[:suite]) &&
             (gitlab_test_info[:nodeset] == test_info[:nodeset]) &&
             (gitlab_test_info[:puppet_version] == test_info[:puppet_version]) &&
             (gitlab_test_info[:fips] == test_info[:fips])
        )
          status = 'included via no suite'
        end
      end
   end
   status
  end
end
