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

  def generate_full_acceptance_matrix(test_info, puppet_versions, include_fips = true)
    component = test_info[:component]
    return [ [component, 'NONE', 'N/A', 'N/A', 'N/A'] ] if test_info[:suites].empty?
    return [ [component, 'NONE', 'N/A', 'N/A', 'N/A'] ] if puppet_versions.nil? || puppet_versions.empty?
    tests = []
    test_info[:suites].each do |suite, config|
      config[:nodesets].each do |nodeset|
        puppet_versions.each do |puppet_version|
          tests << [ component, suite, nodeset, puppet_version, 'disabled' ]
          if include_fips
            tests << [ component, suite, nodeset, puppet_version, 'enabled' ]
          end
        end
      end
    end
    tests
  end

  def get_acceptance_test_info(component_dir)
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
          nodesets = Dir.glob("#{nodeset_dir}/*yml")
        else
          nodesets = Dir.glob("#{global_nodeset_dir}/*yml")
        end
        nodesets.delete_if { |nodeset| File.symlink?(nodeset) }

        suite = File.basename(suite_dir)
        test_info[:suites][suite] = {
          :nodesets => nodesets.map {|nodeset| File.basename(nodeset, '.yml') }
        }

        if suite != 'default'
          test_meta_file = File.join(suite_dir, 'metadata.yml')
          if File.exist?(test_meta_file)
            test_meta = YAML.load(File.read(test_meta_file))
            if test_meta['default_run']
              test_info[:suites][suite][:added_to_default] = true
            end
          end
        end
      end
    end
    test_info
  end

  def get_acceptance_test_matrix(component_dir, puppet_versions)
    test_info = get_acceptance_test_info(component_dir)
    matrix = generate_full_acceptance_matrix(test_info, puppet_versions, true)
    matrix.sort_by { |test_info| test_info.to_s }
  end

  def get_gitlab_acceptance_test_matrix(component_dir)
    gitlab_yaml_file = File.join(component_dir, '.gitlab-ci.yml')
    component = File.basename(component_dir)
    unless File.exist?(gitlab_yaml_file)
      return [ ['N/A'], [ [component, 'NONE', 'N/A', 'N/A', 'N/A'] ] ]
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
      fips = nil
      value['script'].each do |line|
        next unless line.include? 'beaker:suites'
        if line.include?('[')
          match = line.match(/beaker:suites\[(\w*)(,(\w*))?\]/)
          suite = match[1]
          nodeset = match[3]
        else
          suites = Dir.glob("#{component_dir}/spec/acceptance/suites/*")
          suites.delete_if { |x| ! File.directory?(x) }
          if suites.size > 1
            suite = :default_with_additions
          else
            suite = 'default'
          end
          nodeset = 'default'
        end

        if line.include?('BEAKER_fips=yes')
          fips = 'enabled'
        else
          fips = 'disabled'
        end
      end
      next unless suite

      suite.strip! if suite.is_a?(String)
      nodeset = nodeset.nil? ? 'default' : nodeset.strip
      puppet_versions << puppet_version
      tests << [ component, suite, nodeset, puppet_version, fips ]
    end
    tests = [ [component, 'NONE', 'N/A', 'N/A', 'N/A'] ] if tests.empty?
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
end
