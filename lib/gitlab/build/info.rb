require_relative "../build_iteration.rb"
require_relative "check.rb"
require_relative "image.rb"
require 'omnibus'

# To use PROCESS_ID instead of $$ to randomize the target directory for cloning
# GitLab repository. Rubocop requirement to increase readability.
require 'English'

module Build
  class Info
    class << self
      def package
        return "gitlab-ee" if Check.is_ee?

        "gitlab-ce"
      end

      # For nightly builds we fetch all GitLab components from master branch
      # If there was no change inside of the omnibus-gitlab repository, the
      # package version will remain the same but contents of the package will be
      # different.
      # To resolve this, we append a PIPELINE_ID to change the name of the package
      def semver_version
        # timestamp is disabled in omnibus configuration
        Omnibus.load_configuration('omnibus.rb')

        semver = Omnibus::BuildVersion.semver
        if ENV['NIGHTLY'] && ENV['CI_PIPELINE_ID']
          semver = "#{semver}.#{ENV['CI_PIPELINE_ID']}"
        end
        semver
      end

      def release_version
        semver = Info.semver_version
        "#{semver}-#{Gitlab::BuildIteration.new.build_iteration}"
      end

      # TODO, merge latest_tag with latest_stable_tag
      # TODO, add tests, needs a repo clone
      def latest_tag
        `git -c versionsort.prereleaseSuffix=rc tag -l '#{Info.tag_match_pattern}' --sort=-v:refname | head -1`
      end

      def latest_stable_tag
        `git -c versionsort.prereleaseSuffix=rc tag -l '#{Info.tag_match_pattern}' --sort=-v:refname | awk '!/rc/' | head -1`
      end

      def docker_tag
        Info.release_version.tr('+', '-')
      end

      def gitlab_version
        # Get the branch/version/commit of GitLab CE/EE repo against which package
        # is built. If GITLAB_VERSION variable is specified, as in triggered builds,
        # we use that. Else, we use the value in VERSION file.

        if ENV['GITLAB_VERSION'].nil? || ENV['GITLAB_VERSION'].empty?
          File.read('VERSION').strip
        else
          ENV['GITLAB_VERSION']
        end
      end

      def gitlab_rails_repo
        # For normal builds, QA build happens from the gitlab repositories in dev.
        # For triggered builds, they are not available and their gitlab.com mirrors
        # have to be used.

        if ENV['ALTERNATIVE_SOURCES'].to_s == "true"
          domain = "https://gitlab.com/gitlab-org"
          project = package
        else
          domain = "git@dev.gitlab.org:gitlab"

          # GitLab CE repo in dev.gitlab.org is named gitlabhq. So we need to
          # identify gitlabhq from gitlab-ce. Fortunately gitlab-ee does not have
          # this problem.
          project = package == "gitlab-ce" ? "gitlabhq" : "gitlab-ee"
        end

        "#{domain}/#{project}.git"
      end

      def edition
        Info.package.gsub("gitlab-", "").strip # 'ee' or 'ce'
      end

      def release_bucket
        # Tag builds are releases and they get pushed to a specific S3 bucket
        # whereas regular branch builds use a separate one
        Check.on_tag? ? "downloads-packages" : "omnibus-builds"
      end

      def log_level
        if ENV['BUILD_LOG_LEVEL'] && !ENV['BUILD_LOG_LEVEL'].empty?
          ENV['BUILD_LOG_LEVEL']
        else
          'info'
        end
      end

      # Fetch the package from an S3 bucket
      def package_download_url
        package_filename_url_safe = Info.release_version.gsub("+", "%2B")
        "https://#{Info.release_bucket}.s3.amazonaws.com/ubuntu-xenial/#{Info.package}_#{package_filename_url_safe}_amd64.deb"
      end

      def image_name
        "#{ENV['CI_REGISTRY_IMAGE']}/#{Info.package}"
      end

      def triggered_build_package_url
        project_id = ENV['CI_PROJECT_ID']
        pipeline_id = ENV['CI_PIPELINE_ID']
        return unless project_id && !project_id.empty? && pipeline_id && !pipeline_id.empty?

        id = Image.fetch_artifact_url(project_id, pipeline_id)
        "#{ENV['CI_PROJECT_URL']}/builds/#{id}/artifacts/raw/pkg/ubuntu-xenial/gitlab.deb"
      end

      def tag_match_pattern
        return '*[+.]ee.*' if Check.is_ee?

        '*[+.]ce.*'
      end

      def release_file_contents
        repo = ENV['PACKAGECLOUD_REPO'] # Target repository
        token = ENV['TRIGGER_PRIVATE_TOKEN'] # Token used for triggering a build

        download_url = if token && !token.empty?
                         Info.triggered_build_package_url
                       else
                         Info.package_download_url
                       end
        contents = []
        contents << "PACKAGECLOUD_REPO=#{repo.chomp}\n" if repo && !repo.empty?
        contents << "RELEASE_PACKAGE=#{Info.package}\n"
        contents << "RELEASE_VERSION=#{Info.release_version}\n"
        contents << "DOWNLOAD_URL=#{download_url}\n" if download_url
        contents << "TRIGGER_PRIVATE_TOKEN=#{token.chomp}\n" if token && !token.empty?
        contents.join
      end
    end
  end
end