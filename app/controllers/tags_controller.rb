class TagsController < ApplicationController
  include TagsHelper

  before_action :authorize_only_for_admin
  responders :flash

  layout 'assignment_content'

  def index
    @assignment = Assignment.find(params[:assignment_id])

    respond_to do |format|
      format.html
      format.json do
        tags = Tag.includes(:user, :groupings).order(:name)

        tag_info = tags.map do |tag|
          {
            id: tag.id,
            name: tag.name,
            description: tag.description,
            creator: "#{tag.user.first_name} #{tag.user.last_name}",
            use: get_num_groupings_for_tag(tag)
          }
        end

        render json: tag_info
      end
    end
  end

  def edit
    @tag = Tag.find(params[:id])
    @assignment = Assignment.find(params[:assignment_id])
  end

  # Creates a new instance of the tag.
  def create
    new_tag = Tag.new(
      name: params[:create_new][:name],
      description: params[:create_new][:description],
      user: @current_user)

    if new_tag.save
      if params[:grouping_id]
        create_grouping_tag_association(params[:grouping_id], new_tag)
      end
    end

    respond_with new_tag, location: -> { request.headers['Referer'] || root_path }
  end

  def get_all_tags
    Tag.all
  end

  def update
    tag = Tag.find(params[:id])
    tag.name = params[:update_tag][:name]
    tag.description = params[:update_tag][:description]
    tag.save

    respond_with tag, location: -> { request.headers['Referer'] || root_path }
  end

  def destroy
    tag = Tag.find(params[:id])
    tag.destroy
    head :ok
  end

  # Dialog to edit a tag.
  def edit_tag_dialog
    @assignment = Assignment.find(params[:assignment_id])
    @tag = Tag.find(params[:id])

    render partial: 'tags/edit_dialog', handlers: [:erb]
  end

  ###  Upload/Download Methods  ###

  def download_tag_list
    # Gets all the tags
    tags = Tag.all.order(:name)

    case params[:format]
    when 'csv'
      output = MarkusCSV.generate(tags) do |tag|
        user = User.find(tag.user.id)

        [tag.name,
         tag.description,
         "#{user.first_name} #{user.last_name}"]
      end
      format = 'text/csv'
    when 'yaml'
      output = export_tags_yaml
      format = 'text/plain'
    else
      # If there is no 'recognized' format,
      # print to yaml.
      output = export_tags_yaml
      format = 'text/plain'
    end

    # Now we download the data.
    send_data(output,
              type: format,
              filename: "tag_list.#{params[:format]}",
              disposition: 'attachment')
  end

  # Export a YAML formatted string.
  def export_tags_yaml
    tags = Tag.all.order(:name)

    # The final list of all tags.
    final = ActiveSupport::OrderedHash.new

    # Go through and get each of the tags.
    tags.each do |tag|
      current = ActiveSupport::OrderedHash.new
      current['name'] =  tag['name']
      current['description'] = tag['description']

      # Gets user info.
      current_user = User.find(tag['user'])
      current['user'] = {
        'id' => tag['user'],
        'name' => "#{current_user['first_name']} #{current_user['last_name']}"
      }

      tag_yml = { "tag_#{tag['id']}" => current }
      final = final.merge(tag_yml)
    end

    # Outputs it to YAML.
    final.to_yaml
  end

  def csv_upload
    # Gets parameters for the upload
    file = params[:csv_tags]
    encoding = params[:encoding]
    if file
      Tag.transaction do
        result = MarkusCSV.parse(file.read, encoding: encoding) do |row|
          unless CSV.generate_line(row).strip.empty?
            Tag.create_or_update_from_csv_row(row, @current_user)
          end
        end
        unless result[:invalid_lines].empty?
          flash_message(:error, result[:invalid_lines])
        end
        unless result[:valid_lines].empty?
          flash_message(:success, result[:valid_lines])
        end
      end
    else
      flash_message(:error, I18n.t('upload_errors.missing_file'))
    end
    redirect_back(fallback_location: root_path)
  end

  def yml_upload
    # Gets the parameters and encoding.
    errors = ActiveSupport::OrderedHash.new
    file = params[:yml_tags]
    encoding = params[:encoding]

    # Now carries out the parsing.
    if request.post? && !file.blank?
      begin
        tags = YAML::load(file.utf8_encode(encoding))

      # Handles errors associated with loads.
      rescue Psych::SyntaxError => e
        flash_message(:error, t('upload_errors.syntax_error', error: e.to_s))
        redirect_back(fallback_location: root_path)
        return
      end

      # We now parse the file.
      successes = 0
      i = 1
      tags.each do |key|
        begin
          Tag.create_or_update_from_yml_key(key)
          successes += 1
        rescue RuntimeError => e
          # Collect the names of the criterion that contains an error in it.
          errors[i] = key.at(0)
          i = i + 1
        end
      end

      # Handles any errors.
      bad_names = ''
      i = 0
      # Create a String from the OrderedHash of bad criteria separated by commas.
      errors.each_value do |keys|
        if i == 0
          bad_names = keys
          i = i + 1
        else
          bad_names = bad_names + ', ' + keys
        end
      end

      if successes < tags.length
        flash_message(:error, I18n.t('upload_errors.syntax_error', error: bad_names))
      end

      # Displays the tags that are successful.
      if successes > 0
        flash_message(:success, I18n.t(:upload_success, count: successes))
      end
    end

    # Redirects backwards.
    redirect_back(fallback_location: root_path)
  end
end
