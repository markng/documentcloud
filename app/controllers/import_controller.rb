class ImportController < ApplicationController

  FILE_URL = /\Afile:\/\//

  layout nil

  before_filter :login_required, :only => [:upload_document]

  def upload_document
    @bad_request = true and return unless params[:file] && params[:title]
    @project_id  = params[:project_id]
    doc = new_document
    ensure_pdf do |path|
      DC::Store::AssetStore.new.save_pdf(doc, path, params[:access].to_i)
    end
    doc.queue_initial_import(params[:access].to_i)
    @document = doc.reload
  end

  # Returning a "201 Created" ack tells CloudCrowd to clean up the job.
  # If the document failed to import, we remove it.
  def cloud_crowd
    job = JSON.parse(params[:job])
    if job['status'] != 'succeeded'
      logger.error("Document import failed: " + job.inspect)
      record = ProcessingJob.find_by_cloud_crowd_id(job['id'])
      record.document.update_attributes(:access => DC::Access::ERROR) if record && record.document
    end
    ProcessingJob.destroy_all(:cloud_crowd_id => job['id'])
    render :text => '201 Created', :status => 201
  end

  # CloudCrowd is done changing the document's asset access levels.
  # 201 created cleans up the job.
  def update_access
    render :text => '201 Created', :status => 201
  end


  private

  # A new, pending document for the request.
  def new_document
    doc = Document.create!(
      :title            => params[:title],
      :source           => params[:source],
      :description      => params[:description],
      :organization_id  => current_organization.id,
      :account_id       => current_account.id,
      :access           => DC::Access::PENDING,
      :page_count       => 0
    )
    current_account.projects.find(@project_id).add_document(doc) if @project_id
    doc
  end

  # Make sure we're dealing with a PDF. If not, it needs to be
  # converted first. Return the path to the converted document.
  def ensure_pdf
    Dir.mktmpdir do |temp_dir|
      path = params[:file].path
      name = params[:file].original_filename
      ext  = File.extname(name)
      return yield(path) if ext == ".pdf"
      begin
        doc  = File.join(temp_dir, name)
        FileUtils.cp(path, doc)
        Docsplit.extract_pdf(doc, :output => temp_dir)
        yield(File.join(temp_dir, File.basename(name, ext) + '.pdf'))
      rescue Exception => e
        logger.error("PDF Conversion Failed: " + e.message + "\n" + e.backtrace.join("\n"))
        yield path
      end
    end
  end

end