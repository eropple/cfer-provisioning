module Cfer::Provisioning

  def cfn_metadata
    self[:Metadata] ||= {}
  end

  def cfn_auth(name, options = {})
    cfn_metadata['AWS::CloudFormation::Authentication'] ||= {}
    cfn_metadata['AWS::CloudFormation::Authentication'][name] = options
  end

  def cfn_init_setup(options = {})
    cfn_metadata['AWS::CloudFormation::Init'] = {}

    script = [ "#!/bin/bash -xe\n" ]

    script.concat [
      "which cfn-init > /dev/null\n",
      "if [[ $? -ne 0 ]]\n",
      "then\n"
    ]
      script.concat case options[:flavor]
        when :redhat, :centos, :amazon
          [
            "rpm -Uvh https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.amzn1.noarch.rpm\n"
          ]
        when :ubuntu, :debian, nil
          [
            "apt-get update --fix-missing\n",
            "apt-get install -y python-pip\n",
            "pip install setuptools\n",
            "easy_install https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-latest.tar.gz\n",
          ]
      end
    script.concat [
      "fi\n"
    ]

    script.concat [
      "# Helper function\n",
      "function error_exit\n",
      "{\n",
    ]

    if options[:signal]
      script.concat [
        "/usr/local/bin/cfn-signal",
          " -s false",
          " --resource '", options[:signal], "'",
          " --stack ", Cfer::Cfn::AWS::stack_name,
          " --region ", Cfer::Cfn::AWS::region,
          "\n"
        ]
    end

    script.concat [
      "  exit 1\n",
      "}\n"
    ]


    script.concat [
      "/usr/local/bin/cfn-init",
        " --configsets '", Cfer::Core::Fn::join(',', options[:cfn_init_config_set]) || raise('Please specify a `cfn_init_config_set`'), "'",
        " --stack ", Cfer::Cfn::AWS::stack_name,
        " --resource ", @name,
        " --region ", Cfer::Cfn::AWS::region,
        " || error_exit 'Failed to run cfn-init'\n"
    ]

    if options[:cfn_hup_config_set]
      cfn_hup(options)

      script.concat [
        "/usr/local/bin/cfn-hup || error_exit 'Failed to start cfn-hup'\n"
      ]
    end

    if options[:signal]
      script.concat [
        "/usr/local/bin/cfn-signal",
          " -s true",
          " --resource '", options[:signal], "'",
          " --stack ", Cfer::Cfn::AWS::stack_name,
          " --region ", Cfer::Cfn::AWS::region,
          "\n"
        ]
    end

    user_data Cfer::Core::Fn::base64(
      Cfer::Core::Fn::join('', script)
    )
  end

  def config_set(name)
    { "ConfigSet" => name }
  end

  def cfn_init_config_set(name, sections)
    cfg_sets = cloudformation_init['configSets'] || { 'default' => [] }
    cfg_set = Set.new(cfg_sets[name] || [])
    cfg_set.merge sections
    cfg_sets[name] = cfg_set.to_a
    cloudformation_init['configSets'] = cfg_sets
  end

  def cfn_init_config(name, options = {}, &block)
    cfg = ConfigSet.new(cloudformation_init[name])
    cfg.instance_eval(&block)
    cloudformation_init[name] = cfg.to_h
  end

  private

  class ConfigSet
    def initialize(hash)
      @config_set = hash || {}
    end

    def to_h
      @config_set
    end

    def commands
      @config_set['commands'] ||= {}
    end

    def files
      @config_set['files'] ||= {}
    end

    def packages
      @config_set['packages'] ||= {}
    end

    def command(name, cmd, options = {})
      commands[name] = options.merge('command' => cmd)
    end

    def file(path, options = {})
      files[path] = options
    end

    def package(type, name, versions = [])
      packages[type] ||= {}
      packages[type][name] = versions
    end
  end

  def cloudformation_init(options = {})
    cfn_metadata['AWS::CloudFormation::Init'] ||= {}
  end


  def cfn_hup(options)
    resource_name = @name
    target_config_set = options[:cfn_hup_config_set] || raise('Please specify a `cfn_hup_config_set`')

    cfn_init_config_set :cfn_hup, [ :cfn_hup ]

    cfn_init_config(:cfn_hup) do
      if options[:access_key] && options[:secret_key]
        file '/etc/cfn/cfn-credentials', content: Cfer::Core::Fn::join('', [
          "AWSAccessKeyId=", options[:access_key], "\n",
          "AWSSecretKey=", options[:secret_key], "\n"
        ]),
        mode: '000400',
        owner: 'root',
        group: 'root'
      end

      file '/etc/cfn/cfn-hup.conf', content: Cfer::Core::Fn::join('', [
        "[main]\n",
        "stack=", Cfer::Cfn::AWS::stack_name, "\n",
        "region=", Cfer::Cfn::AWS::region, "\n",
        "interval=", options[:interval] || 1, "\n"
      ]),
      mode: '000400',
      owner: 'root',
      group: 'root'

      file '/etc/cfn/hooks.d/cfn-init-reload.conf', content: Cfer::Core::Fn::join('', [
        "[cfn-auto-reloader-hook]\n",
        "triggers=post.update\n",
        "path=Resources.#{resource_name}.Metadata\n",
        "action=/usr/local/bin/cfn-init",
          " -c '", Cfer::Core::Fn::join(',', target_config_set), "'",
          " -s ", Cfer::Cfn::AWS::stack_name,
          " --region ", Cfer::Cfn::AWS::region,
          " -r #{resource_name}",
          "\n",
        "runas=root\n"
      ])
    end
  end
end

