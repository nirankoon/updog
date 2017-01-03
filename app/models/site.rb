class Site < ActiveRecord::Base
  belongs_to :user
  attr_accessor :passcode
  has_many :clicks
  has_many :contacts
  has_paper_trail
  validates :subdomain, uniqueness: { case_sensititve: false }
  validates :name, presence: true
  validates :domain, uniqueness: { case_sensititve: false, allow_blank: true }
  validate :domain_isnt_updog
  validate :domain_is_a_subdomain
  before_validation :namify
  after_create :notify_drip

  before_save :encrypt_password
  after_save :clear_password

  def encrypt_password
    if passcode.present?
      self.encrypted_passcode= Digest::SHA2.hexdigest(passcode)
    end
  end

  def clear_password
    self.passcode = nil
  end

  def to_param
      "#{id}-#{name.parameterize}"
  end

  def creator
    self.user
  end

  def identity
    Identity.find_by(user: self.user, provider: self.provider)
  end

  def index path
    path = path.gsub('/directory-index.html','')
    url = 'https://api.dropboxapi.com/2/files/list_folder'
    if self.db_path && self.db_path != ""
      at = self.identity && self.identity.full_access_token
      folder = self.db_path
    else
      at = self.identity && self.identity.access_token
      folder = '/' + self.name
    end
    old_path = path
    document_root = self.document_root || ''
    file_path = folder + '/' + document_root + '/' + path
    file_path = file_path.gsub(/\/+/,'/')

    opts = {
      headers: {
        'Authorization' => "Bearer #{at}",
        'Content-Type' => 'application/json',
      },
      body: {
        path: file_path
      }.to_json
    }
    res = HTTParty.post(url, opts)
    res["entries"] = res["entries"].select{|entry| entry["name"] != 'directory-index.html'}
    res.merge("path" => path)
  end

  def content uri, dir = nil
    path = URI.unescape(uri)
    out = Rails.cache.fetch("#{cache_key}/#{path}") do
      from_api uri, path, dir
    end
    if (Time.now - self.updated_at) > 5
      ContentWorker.perform_async(self.id, uri, path, cache_key)
    end
    out
  end

  def from_api uri, path, dir
    puts "CALLING API"
    if self.provider == 'dropbox'
      dropbox_content uri, path
    elsif self.provider == 'google'
      google_content uri, path, dir
    end
  end

  def subcollection_from_uri uri, dir
    folders = uri.split("/")
    folders.shift # the empty initial slash
    folders.pop # the file
    google_folders = dir.files(q:'mimeType = "application/vnd.google-apps.folder"')
    last_parent = dir
    folders.each do |folder|
      subcollection = google_folders.select{ |gf|
        gf.parents.include?(last_parent.id) && gf.title == folder
      }.first
      last_parent = subcollection
    end
    last_parent
  end

  def title_from_uri uri
    folders = uri.split("/")
    folders.pop # the file
  end

  def google_content uri, path, dir
    file_path = '/' + self.name + '/' + path
    file_path = file_path.gsub(/\/+/,'/')
    folda = subcollection_from_uri(uri, dir) || dir
    title = title_from_uri(uri)
    oat = folda.file_by_title(title || '')
    oat = oat.nil? ? "Error in call to API function" : oat.download_to_string.html_safe
    oat = oat.gsub("</body>","#{injectee}</body>").html_safe if inject?
    oat
  end

  def dropbox_content uri, path
    if self.db_path && self.db_path != ""
      at = self.identity && self.identity.full_access_token
      folder = self.db_path
    else
      at = self.identity && self.identity.access_token
      folder = '/' + self.name
    end
    document_root = self.document_root || ''
    file_path = folder + '/' + document_root + '/' + path
    file_path = file_path.gsub(/\/+/,'/')
    url = 'https://content.dropboxapi.com/2/files/download'
    opts = {
      headers: {
        'Authorization' => "Bearer #{at}",
        'Content-Type' => '',
        'Dropbox-API-Arg' => {
          path: file_path
        }.to_json
      }
    }
    Rails.logger.info "Requesting https://#{self.name}.updog.co#{file_path.gsub(self.name+'/','')}"
    Rails.logger.info "Dropbox file path: #{file_path}"
    Rails.logger.info "Document root: #{self.document_root}"
    Rails.logger.info "Db path: #{self.db_path}"
    res = HTTParty.post(url, opts)
    oat = res.body.html_safe
    oat = "Not found - Please Reauthenticate Dropbox" if oat.match("Invalid authorization value")
    oat
  end

  def inject?
    (!self.creator.is_pro && self.creator.id > 1547) || Rails.env.development?
  end

  def domain_isnt_updog
    if self.domain =~ /updog\.co/
      errors.add(:domain, "can't contain updog.co")
    end
  end

  def domain_is_a_subdomain
    if self.domain && self.domain != "" && self.domain !~ /\w+\.[\w-]+\.\w+/
      errors.add(:domain, "must have a subdomain like www.")
    end
  end

  def link
    if self.domain && self.domain != ""
      self.domain
    else
      self.subdomain
    end
  end
  def self.created_today
    where("created_at > ?", Time.now.beginning_of_day)
  end
  def self.popular
    joins(:clicks).
    group("sites.id").
    where("clicks.created_at > ?", Time.now.beginning_of_day).
    order("count(clicks.id) DESC").
    limit(10)
  end
  def clicks_today
    clicks.where('created_at > ?', Time.now.beginning_of_day)
  end

  def dir
    if self.provider == 'google'
      begin
        identity = self.user.identities.find_by(provider: self.provider)
        sesh = GoogleDrive::Session.from_access_token(identity.access_token)
        dir = sesh.file_by_id(self.google_id)
      rescue => e
        if e.to_s == "Unauthorized"
          identity.refresh_access_token
          return google_session site
        else
          raise e
        end
      end
      dir
    end
  end

  private
  def notify_drip
    Drip.event self.creator.email, 'created a site'
  end
   def  namify
    self.name.downcase!
    self.name = self.name.gsub(/[^\w+]/,'-')
    self.name = self.name.gsub(/-+$/,'')
    self.name = self.name.gsub(/^-+/,'')
    self.subdomain = self.name + '.updog.co'
  end

end
