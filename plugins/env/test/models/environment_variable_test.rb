# frozen_string_literal: true
require_relative "../test_helper"

SingleCov.covered!

describe EnvironmentVariable do
  let(:project) { stage.project }
  let(:stage) { stages(:test_staging) }
  let(:deploy_group) { stage.deploy_groups.first }
  let(:environment) { deploy_group.environment }
  let(:deploy_group_scope_type_and_id) { "DeployGroup-#{deploy_group.id}" }
  let(:environment_variable) { EnvironmentVariable.new(name: "NAME", parent: project, value: "foo") }

  describe "validations" do
    # postgres and sqlite do not have string limits defined
    if ActiveRecord::Base.connection.class.name == "ActiveRecord::ConnectionAdapters::Mysql2Adapter"
      it "validates value length" do
        environment_variable.value = "a" * 1_000_000
        refute_valid environment_variable
      end
    end
  end

  describe ".env" do
    before do
      EnvironmentVariableGroup.create!(
        environment_variables_attributes: {
          0 => {name: "X", value: "Y"},
          2 => {name: "Z", value: "A", scope: deploy_group}
        },
        name: "G1"
      )
      EnvironmentVariableGroup.create!(
        environment_variables_attributes: {
          1 => {name: "Y", value: "Z"}
        },
        name: "G2"
      )
    end

    it "is empty for nothing" do
      EnvironmentVariable.env(Project.new, nil).must_equal({})
      EnvironmentVariable.env(Project.new, 123).must_equal({})
    end

    describe "with an assigned group and variables" do
      before do
        project.environment_variable_groups = EnvironmentVariableGroup.all
        project.environment_variables.create!(name: "PROJECT", value: "DEPLOY", scope: deploy_group)
        project.environment_variables.create!(name: "PROJECT", value: "PROJECT")
      end

      it "includes only common for common groups" do
        EnvironmentVariable.env(project, nil).must_equal("X" => "Y", "Y" => "Z", "PROJECT" => "PROJECT")
      end

      it "includes common for scoped groups" do
        EnvironmentVariable.env(project, deploy_group).must_equal(
          "PROJECT" => "DEPLOY", "X" => "Y", "Z" => "A", "Y" => "Z"
        )
      end

      it "overwrites environment groups with project variables" do
        project.environment_variables.create!(name: "X", value: "OVER")
        EnvironmentVariable.env(project, nil).must_equal("X" => "OVER", "Y" => "Z", "PROJECT" => "PROJECT")
      end

      it "keeps correct order for different priorities" do
        project.environment_variables.create!(name: "PROJECT", value: "ENV", scope: environment)

        project.environment_variables.create!(name: "X", value: "ALL")
        project.environment_variables.create!(name: "X", value: "ENV", scope: environment)
        project.environment_variables.create!(name: "X", value: "GROUP", scope: deploy_group)

        project.environment_variables.create!(name: "Y", value: "ENV", scope: environment)
        project.environment_variables.create!(name: "Y", value: "ALL")

        EnvironmentVariable.env(project, deploy_group).must_equal(
          "X" => "GROUP", "Y" => "ENV", "PROJECT" => "DEPLOY", "Z" => "A"
        )
      end

      it "produces few queries when doing multiple versions as the env builder does" do
        groups = DeployGroup.all.to_a
        assert_sql_queries 2 do
          EnvironmentVariable.env(project, nil)
          groups.each { |deploy_group| EnvironmentVariable.env(project, deploy_group) }
        end
      end

      it "can resolve references" do
        project.environment_variables.last.update_column(:value, "PROJECT--$POD_ID--$POD_ID_NOT--${POD_ID}")
        project.environment_variables.create!(name: "POD_ID", value: "1")
        EnvironmentVariable.env(project, nil).must_equal(
          "PROJECT" => "PROJECT--1--$POD_ID_NOT--1", "POD_ID" => "1", "X" => "Y", "Y" => "Z"
        )
      end

      it "can does not cache resolved references" do
        project.environment_variables.last.update_column(:value, "PROJECT--$POD_ID")
        project.environment_variables.create!(name: "POD_ID", value: "1", scope: deploy_groups(:pod1))
        project.environment_variables.create!(name: "POD_ID", value: "2", scope: deploy_groups(:pod2))
        EnvironmentVariable.env(project, deploy_groups(:pod1)).must_equal(
          "PROJECT" => "PROJECT--1", "POD_ID" => "1", "X" => "Y", "Y" => "Z"
        )
        EnvironmentVariable.env(project, deploy_groups(:pod2)).must_equal(
          "PROJECT" => "PROJECT--2", "POD_ID" => "2", "X" => "Y", "Y" => "Z"
        )
      end

      describe "secrets" do
        before do
          create_secret 'global/global/global/foobar'
          project.environment_variables.last.update_column(:value, "secret://foobar")
        end

        it "can resolve secrets" do
          EnvironmentVariable.env(project, nil).must_equal(
            "PROJECT" => "MY-SECRET", "X" => "Y", "Y" => "Z"
          )
        end

        it "does not resolve secrets when asked to not do it" do
          EnvironmentVariable.env(project, nil, resolve_secrets: false).must_equal(
            "PROJECT" => "secret://foobar", "X" => "Y", "Y" => "Z"
          )
        end

        it "fails on unfound secrets" do
          Samson::Secrets::Manager.delete 'global/global/global/foobar'
          e = assert_raises Samson::Hooks::UserError do
            EnvironmentVariable.env(project, nil)
          end
          e.message.must_include "Failed to resolve secret keys:\n\tfoobar"
        end

        it "does not show secret values in preview mode" do
          EnvironmentVariable.env(project, nil, preview: true).must_equal(
            "PROJECT" => "secret://global/global/global/foobar", "X" => "Y", "Y" => "Z"
          )
        end

        it "does not duplicate secret values in preview mode" do
          all = DeployGroup.all.map do |dg|
            EnvironmentVariable.env(project, dg, preview: true)
          end
          all.sort_by { |x| x["PROJECT"] }.must_equal(
            [
              {"PROJECT" => "DEPLOY", "Z" => "A", "X" => "Y", "Y" => "Z"},
              {"PROJECT" => "secret://global/global/global/foobar", "X" => "Y", "Y" => "Z"},
              {"PROJECT" => "secret://global/global/global/foobar", "X" => "Y", "Y" => "Z"}
            ]
          )
        end

        it "does not raise on missing secret values in preview mode" do
          Samson::Secrets::Manager.delete 'global/global/global/foobar'
          EnvironmentVariable.env(project, nil, preview: true).must_equal(
            "PROJECT" => "secret://foobar X", "X" => "Y", "Y" => "Z"
          )
        end
      end
    end
  end

  describe ".sort_by_scopes" do
    it "sorts by name, type, id" do
      a = environments(:production)
      b = environments(:staging)
      variables = [
        EnvironmentVariable.new(name: "A", scope_type: "Environment", scope_id: a.id),
        EnvironmentVariable.new(name: "A", scope_type: "DeployGroup", scope_id: 1),
        EnvironmentVariable.new(name: "B", scope_type: "Environment", scope_id: a.id),
        EnvironmentVariable.new(name: "A", scope_type: "Environment", scope_id: b.id),
        EnvironmentVariable.new(name: "A", scope_type: "Environment", scope_id: a.id),
        EnvironmentVariable.new(name: "A", scope_type: "Environment", scope_id: b.id),
      ]
      scopes = Environment.env_deploy_group_array
      result = EnvironmentVariable.sort_by_scopes(variables, scopes).map { |e| "#{e.name}-#{e.scope&.name}" }
      result.must_equal(["A-Production", "A-Production", "A-Staging", "A-Staging", "A-", "B-Production"])
    end
  end

  describe '.variables_to_string' do
    it 'displays environment variables as a string' do
      variables = [
        EnvironmentVariable.new(name: "FOO", value: 'bar', scope: environments(:production)),
        EnvironmentVariable.new(name: "MARCO", value: 'polo', scope: environments(:staging))
      ]

      scopes = Environment.env_deploy_group_array

      expected = %(FOO="bar" # Production\nMARCO="polo" # Staging)
      EnvironmentVariable.serialize(variables, scopes).must_equal expected
    end
  end

  describe "#auditing_enabled" do
    it "creates audits for regular vars" do
      assert_difference "Audited::Audit.count", +1 do
        environment_variable.save!
      end
    end

    it "does not audit deploys which never change" do
      environment_variable.parent = deploys(:succeeded_test)
      assert_difference "Audited::Audit.count", 0 do
        environment_variable.save!
      end
    end
  end
end
