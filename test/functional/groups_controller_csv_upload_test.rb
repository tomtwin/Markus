require File.expand_path(File.join(File.dirname(__FILE__),  'authenticated_controller_test'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', 'test_helper'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', 'blueprints', 'blueprints'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', 'blueprints', 'helper'))
include CsvHelper
require 'shoulda'
require 'mocha/setup'
require 'fileutils'

include MarkusConfigurator
include ActionDispatch::TestProcess

# Tests proper workings of MarkUs repository creation when a particular
# setup of assignment and group sizes is used. This test suite uses
# SubversionRepository instead of MemoryRepository.
class GroupsControllerCsvUploadTest < AuthenticatedControllerTest
  context 'An authenticated and authorized admin' do

    # We need to use SubversionRepository for this test suite
    setup do

      # Non-standard controller test. Rails expects @controller to be set
      @controller = GroupsController.new

      # Setup for SubversionRepository
      MarkusConfigurator.stubs(:markus_config_repository_type).returns('svn')
      # Write repositories to tmp
      @repository_storage = File.join(::Rails.root.to_s, 'tmp', 'groups_controller_repos')
      MarkusConfigurator.stubs(:markus_config_repository_storage).returns(@repository_storage)
      MarkusConfigurator.stubs(:markus_config_repository_permission_file).returns(
            File.join( @repository_storage, 'svn_authz') )
    end

    context 'on an assignment with allow_web_submits set to false and group max of 1' do

      setup do
        # Keep the previous working directory
        # If not, having shell-init errors on Linux/MacOSX machines
        @pwd = FileUtils.pwd
        FileUtils.mkdir @repository_storage
        FileUtils.touch File.join(@repository_storage, 'svn_authz')
        @admin = Admin.make

        # Available CSV files (in test/groups_csvs):
        #   - autogenerated_repos_groups.csv: should produce autogenerated names only
        #   - mixed_repos_groups.csv: should produce autogenerated repo names and some with a
        #                             particular name
        #   - non_admin_repos_groups.csv: should use repository names of second field
        #   - username_repos_groups.csv: should use usernames as repo names
        @autogen_repos_csv_file = fixture_file_upload(
                                    File.join(
                                        'group_csvs',
                                        'autogenerated_repos_groups.csv'))
        @non_admin_repos_csv_file = fixture_file_upload(
                                      File.join(
                                          'group_csvs',
                                          'non_admin_repos_groups.csv'))
        @username_repos_csv_file = fixture_file_upload(
                                      File.join(
                                          'group_csvs',
                                          'username_repos_groups.csv'))

        # Make students appearing in the csvs
        Student.make(:user_name => 'c6scriab')
        Student.make(:user_name => 'c5berkel')
        Student.make(:user_name => 'c5anthei')
        Student.make(:user_name => 'c5charpe')
        Student.make(:user_name => 'c5cagejo')
        Student.make(:user_name => 'c5gliere')
      end

      teardown do
        FileUtils.rm_r(@repository_storage, :force => true)
        FileUtils.cd(@pwd)
      end

      context 'should be able to upload groups using CSV file upload, and repos' do
        setup do
          # We want to be repo admin
          MarkusConfigurator.stubs(:markus_config_repository_admin?).returns(true)
          @assignment = Assignment.make(:allow_web_submits => false,
                                        :group_max => 1, :group_min => 1)
          @res = post_as @admin, :csv_upload, { :assignment_id => @assignment.id, :group => { :grouplist=> @username_repos_csv_file } }
        end

        should 'be named after student usernames only' do
          expected_list = %w(c6scriab c5anthei c5cagejo c5charpe)
          assert_equal(Dir.chdir(@repository_storage), 0)
          assert_equal(expected_list.sort, Dir.glob('c*').sort, 'Expected repositories to be named after usernames')
          assert_equal([], Dir.glob('group_*'), 'Did not expect autogenerated repository names')
        end
        should 'route properly' do
          assert_recognizes({:controller => 'groups', :assignment_id => '1', :action => 'csv_upload' },
            {:path => 'assignments/1/groups/csv_upload', :method => :post})
        end
      end

      context 'should be able to upload groups using CSV file upload, and repos' do
        setup do
          # We want to be repo admin
          MarkusConfigurator.stubs(:markus_config_repository_admin?).returns(true)
          @assignment = Assignment.make(:allow_web_submits => true,
                                        :group_max => 1, :group_min => 1)
          @res = post_as @admin, :csv_upload, {:assignment_id => @assignment.id, :group => { :grouplist=> @username_repos_csv_file } }
        end

        should 'have autogenerated names because web submits are allowed' do
          # Note: Assignment allows web submits
          assert_equal(Dir.chdir(@repository_storage), 0)
          assert_equal(4, Dir.glob('group_*').length)
          assert_equal([], Dir.glob('c*'), 'Did not expect repository names similar to usernames')
        end

      end

      context 'should be able to upload groups using CSV file upload, and repos' do

        setup do
          # We want to be repo admin
          MarkusConfigurator.stubs(:markus_config_repository_admin?).returns(true)
          @assignment = Assignment.make(:allow_web_submits => false,
                                        :group_max => 1, :group_min => 1)
          @res = post_as @admin, :csv_upload, { :assignment_id => @assignment.id, :group => { :grouplist=> @autogen_repos_csv_file } }
        end

        should 'have autogenerated names only' do
          # Groupnames are not identical with student's usernames, so should use
          # autogenerated names.
          assert_equal(Dir.chdir(@repository_storage), 0)
          assert_equal(5, Dir.glob('group_*').length)
          assert_equal([], Dir.glob('c*'), 'Did not expect repository names similar to usernames')
        end

      end

      context 'should be able to upload groups using CSV file upload, and repos' do

        setup do
          # We do *not* want to be admin
          MarkusConfigurator.stubs(:markus_config_repository_admin?).returns(false)
          @assignment = Assignment.make(:invalid_override => true,
                                        :group_min => 1, :group_max => 3,
                                        :student_form_groups => false)
          @res = post_as @admin, :csv_upload, { :assignment_id => @assignment.id, :group => { :grouplist=> @non_admin_repos_csv_file } }
        end

        should 'have the names as provided in the csv file' do
          # Repository names should be something like "repoX", where X is a number
          assert_equal(Dir.chdir(@repository_storage), 0)
          expected_list = %w(repo1 repo2 repo3 repo4)
          repo_names = Group.all.map{ |g| g.repository_name }
          assert_equal(expected_list.sort, repo_names.sort)
          assert_equal(0, Dir.glob('repo*').length)
          assert_equal([], Dir.glob('group_*'), 'Did not expect any repositories.')
        end

      end
    end
  end
end
