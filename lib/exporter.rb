# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "zip/filesystem"

require "use_case/data_export/answers"
require "use_case/data_export/appendables"
require "use_case/data_export/comments"
require "use_case/data_export/inbox_entries"
require "use_case/data_export/mute_rules"
require "use_case/data_export/questions"
require "use_case/data_export/relationships"
require "use_case/data_export/theme"
require "use_case/data_export/user"

# the justask data exporter, now with 200% less shelling out to system tools!
#
# the data export can be easily extended by subclassing `UseCase::DataExport::Base`
# and `require`ing it above
class Exporter
  def initialize(user)
    @user = user

    @export_name = "export-#{@user.id}-#{SecureRandom.base36(32)}"
    FileUtils.mkdir_p(Rails.public_path.join("export")) # ensure the public export path exists
    export_zipfile_path = Rails.public_path.join("export", "#{@export_name}.zip")
    @zipfile = Zip::File.open(export_zipfile_path, Zip::File::CREATE)
  end

  def export
    @user.export_processing = true
    @user.save validate: false

    prepare_zipfile
    write_files
    publish
  rescue => e
    Sentry.capture_exception(e)
    @user.export_processing = false
    @user.save validate: false
    raise # so that e.g. the sidekiq job fails
  ensure
    @zipfile.close
  end

  private

  # creates some directories we want to exist and sets a nice comment
  def prepare_zipfile
    @zipfile.mkdir(@export_name)
    @zipfile.mkdir("#{@export_name}/pictures")

    @zipfile.comment = <<~COMMENT
      #{APP_CONFIG.fetch(:site_name)} export done for #{@user.screen_name} on #{Time.now.utc.iso8601}
    COMMENT
  end

  # writes the files to the zip file
  def write_files
    UseCase::DataExport::Base.descendants.each do |export_klass|
      export_klass.call(user: @user).each do |file_name, contents|
        @zipfile.file.open("#{@export_name}/#{file_name}", "wb".dup) do |file| # .dup because of %(can't modify frozen String: "wb")
          file.write contents
        end
      end
    end
  end

  def publish
    url = "#{APP_CONFIG['https'] ? 'https' : 'http'}://#{APP_CONFIG['hostname']}/export/#{@export_name}.zip"
    @user.export_processing = false
    @user.export_url = url
    @user.export_created_at = Time.now.utc
    @user.save validate: false
    url
  end
end
