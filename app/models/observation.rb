class Observation < ActiveRecord::Base
  acts_as_activity_streamable :batch_window => 30.minutes, 
    :batch_partial => "observations/activity_stream_batch"
  acts_as_taggable
  acts_as_flaggable
  
  # Set to true if you want to skip the expensive updating of all the user's
  # lists after saving.  Useful if you're saving many observations at once and
  # you want to update lists in a batch
  attr_accessor :skip_refresh_lists, :skip_identifications

  belongs_to :user, :counter_cache => true
  belongs_to :taxon, :counter_cache => true
  belongs_to :iconic_taxon, :class_name => 'Taxon', 
                            :foreign_key => 'iconic_taxon_id'
  has_many :observation_photos, :dependent => :destroy
  has_many :photos, :through => :observation_photos
  has_many :listed_taxa, :foreign_key => 'last_observation_id'
  has_many :goal_contributions,
           :as => :contribution,
           :dependent => :destroy
  has_many :comments, :as => :parent, :dependent => :destroy
  has_many :identifications, :dependent => :delete_all
  has_many :project_observations, :dependent => :destroy
  
  define_index do
    indexes taxon.taxon_names.name, :as => :names
    indexes tags.name, :as => :tags
    indexes :species_guess, :sortable => true
    indexes :description
    indexes :place_guess, :as => :place, :sortable => true
    indexes user.login, :as => :user, :sortable => true
    indexes :observed_on_string
    has :user_id
    has :taxon_id
    
    # Sadly, the following doesn't work, because self_and_ancestors is not an
    # association.  I'm not entirely sure if there's a way to work the ancestry
    # query in as col in a SQL query on observations.  If at some point we
    # need to have the ancestor ids in the Sphinx index, though, we can always
    # add a col to the taxa table holding the ancestor IDs.  Kind of a
    # redundant, and it would slow down moves, but it might be worth it for
    # the snappy searches. --KMU 2009-04-4
    # has taxon.self_and_ancestors(:id), :as => :taxon_self_and_ancestors_ids
    
    has photos(:id), :as => :has_photos, :type => :boolean
    has :created_at, :sortable => true
    has :observed_on, :sortable => true
    has :iconic_taxon_id
    has :id_please, :as => :has_id_please
    has "latitude IS NOT NULL AND longitude IS NOT NULL", 
      :as => :has_geo, :type => :boolean
    has 'RADIANS(latitude)', :as => :latitude,  :type => :float
    has 'RADIANS(longitude)', :as => :longitude,  :type => :float
    has "num_identification_agreements > num_identification_disagreements",
      :as => :identifications_most_agree, :type => :boolean
    has "num_identification_agreements > 0", 
      :as => :identifications_some_agree, :type => :boolean
    has "num_identification_agreements < num_identification_disagreements",
      :as => :identifications_most_disagree, :type => :boolean
    has project_observations(:project_id), :as => :projects, :type => :multi
    set_property :delta => :delayed
  end

  ##
  # Validations
  #
  validates_presence_of :user_id
  
  validate :must_be_in_the_past,
           :must_not_be_a_range
  
  validates_numericality_of :latitude, {
    :on => :create, 
    :allow_nil => true, 
    :less_than_or_equal_to => 90, 
    :greater_than_or_equal_to => -90
  }
  validates_numericality_of :longitude, {
    :on => :create, 
    :allow_nil => true, 
    :less_than_or_equal_to => 180, 
    :greater_than_or_equal_to => -180
  }
  
  before_validation :munge_observed_on_with_chronic,
                    :set_time_zone,
                    :set_time_in_time_zone,
                    :cast_lat_lon
  
  before_save :strip_species_guess,
              :set_taxon_from_species_guess,
              :set_iconic_taxon,
              :keep_old_taxon_id,
              :set_latlon_from_place_guess,
              :set_positional_accuracy
                 
  after_save :refresh_lists,
             :update_identifications_after_save
             
  
  before_destroy :keep_old_taxon_id
  after_destroy :refresh_lists_after_destroy
  
  # Activity updates
  # after_save :update_activity_update
  # before_destroy :delete_activity_update
  
  ##
  # Named scopes
  # 
  
  # Area scopes
  named_scope :in_bounding_box, lambda { |swlat, swlng, nelat, nelng|
    if swlng.to_f > 0 && nelng.to_f < 0
      {:conditions => ['latitude > ? AND latitude < ? AND (longitude > ? OR longitude < ?)',
                        swlat, nelat, swlng, nelng]}
    else
      {:conditions => ['latitude > ? AND latitude < ? AND longitude > ? AND longitude < ?',
                        swlat, nelat, swlng, nelng]}
    end
  } do
    def distinct_taxon
      all(:group => "taxon_id", :conditions => "taxon_id > 0", :include => :taxon)
    end
  end
  
  # inneficient radius in kilometers
  # See http://www.movable-type.co.uk/scripts/latlong-db.html for the math
  named_scope :near_point, Proc.new { |lat, lng, radius|
    radius ||= 10.0
    planetary_radius = 6371 # km
    deg_per_rad = 57.2958
    latrads = lat.to_f / deg_per_rad
    lngrads = lng.to_f / deg_per_rad

    {:conditions => [
      "#{planetary_radius} * acos(sin(?) * sin(latitude/57.2958) + "  + 
      'cos(?) * cos(latitude/57.2958) *  cos(longitude/57.2958 - ?)) < ?',
      latrads, latrads, lngrads, radius
    ]}    
  }
  
  # Has_property scopes
  named_scope :has_taxon, lambda { |taxon_id|
    if taxon_id.nil?
    then return {:conditions => "taxon_id > 0"}
    else {:conditions => ["taxon_id IN (?)", taxon_id]}
    end
  }
  named_scope :has_iconic_taxa, lambda { |iconic_taxon_ids|
    iconic_taxon_ids = [iconic_taxon_ids].flatten # make array if single
    if iconic_taxon_ids.include?(nil)
      {:conditions => [
        "observations.iconic_taxon_id IS NULL OR observations.iconic_taxon_id IN (?)", 
        iconic_taxon_ids]}
    elsif !iconic_taxon_ids.empty?
      {:conditions => [
        "observations.iconic_taxon_id IN (?)", iconic_taxon_ids]}
    end
  }
  
  named_scope :has_geo, :conditions => ["latitude IS NOT NULL AND longitude IS NOT NULL"]
  named_scope :has_id_please, :conditions => ["id_please IS TRUE"]
  named_scope :has_photos, 
              :include => :photos,
              :group => 'observations.id',
              :conditions => ['photos.id > 0']
  
  
  # Find observations by a taxon object.  Querying on taxa columns forces 
  # massive joins, it's a bit sluggish
  named_scope :of, lambda { |taxon|
    taxon = Taxon.find_by_id(taxon) unless taxon.is_a? Taxon
    return {:conditions => "1 = 2"} unless taxon
    {
      :include => :taxon,
      :conditions => [
        "observations.taxon_id = ? OR taxa.ancestry LIKE '#{taxon.ancestry}/#{taxon.id}%'", 
        taxon
      ]
    }
  }
  
  # Find observations by user
  named_scope :by, lambda { |user| 
    {:conditions => ["observations.user_id = ?", user]}
  }
  
  # Order observations by date and time observed
  named_scope :latest, :order => "observed_on DESC, time_observed_at DESC"
  named_scope :recently_added, :order => "observations.id DESC"
  
  # TODO: Make this work for any SQL order statement, including multiple cols
  named_scope :order_by, lambda { |order|
    order_by, order = order.split == [order] ? [order, 'ASC'] : order.split
    options = {}
    case order_by
    when 'observed_on'
      options[:order] = "observed_on #{order}, " + 
                        "time_observed_at #{order}"
    when 'user'
      options[:include] = [:user]
      options[:order] = "users.login #{order}"
    when 'place'
      options[:order] = "place_guess #{order}"
    when 'created_at'
      options[:order] = "observations.created_at #{order}"
    else
      options[:order] = "#{order_by} #{order}"
    end
    options
  }
  
  named_scope :identifications, lambda { |agreement|
    limited_scope = {:include => :identifications}
    case agreement
    when 'most_agree'
      limited_scope[:conditions] = "num_identification_agreements > num_identification_disagreements"
    when 'some_agree'
      limited_scope[:conditions] = "num_identification_agreements > 0"
    when 'most_disagree'
      limited_scope[:conditions] = "num_identification_agreements < num_identification_disagreements"
    end
    limited_scope
  }
  
  # Time based named scopes
  named_scope :created_after, lambda { |time|
    {:conditions => ['created_at >= ?', time]}
  }
  
  named_scope :created_before, lambda { |time|
    {:conditions => ['created_at <= ?', time]}
  }
  
  named_scope :updated_after, lambda { |time|
    {:conditions => ['updated_at >= ?', time]}
  }
  
  named_scope :updated_before, lambda { |time|
    {:conditions => ['updated_at <= ?', time]}
  }
  
  named_scope :observed_after, lambda { |time|
    {:conditions => ['time_observed_at >= ?', time]}
  }
  
  named_scope :observed_before, lambda { |time|
    {:conditions => ['time_observed_at <= ?', time]}
  }
  
  named_scope :in_projects, lambda { |projects|
    projects = projects.split(',') if projects.is_a?(String)
    {
      :include => :project_observations,
      :conditions => ["project_observations.project_id IN (?)", projects]
    }
  }
  
  def self.near_place(place)
    place = Place.find_by_id(place) unless place.is_a?(Place)
    if place.swlat
      Observation.in_bounding_box(place.swlat, place.swlng, place.nelat, place.nelng).scoped({})
    else
      Observation.near_point(place.latitude, place.longitude).scoped({})
    end
  end
  
  #
  # Uses scopes to perform a conditional search.
  # May be worth looking into squirrel or some other rails friendly search add on
  #
  def self.query(params = {})
    scope = self.scoped({})
    
    # support bounding box queries
     if (!params[:swlat].blank? && !params[:swlng].blank? && 
         !params[:nelat].blank? && !params[:nelng].blank?)
      scope = scope.in_bounding_box(params[:swlat], params[:swlng], params[:nelat], params[:nelng])
    elsif params[:lat] && params[:lng]
      scope = scope.near_point(params[:lat], params[:lng], params[:radius])
    end
    
    # has (boolean) selectors
    if (params[:has])
      params[:has] = params[:has].split(',') if params[:has].is_a? String
      params[:has].each do |prop|
        scope = case prop
          when 'geo' then scope.has_geo
          when 'id_please' then scope.has_id_please
          when 'photos' then scope.has_photos
          else scope.conditions "? IS NOT NULL OR ? != ''", prop, prop # hmmm... this seems less than ideal
        end
      end
    end
    scope = scope.identifications(params[:identifications]) if (params[:identifications])
    scope = scope.has_iconic_taxa(params[:iconic_taxa]) if params[:iconic_taxa]
    scope = scope.order_by(params[:order_by]) if params[:order_by]
    if !params[:taxon_id].blank?
      scope = scope.of(params[:taxon_id])
    elsif !params[:taxon_name].blank?
      name = params[:taxon_name].split('_').join(' ')
      taxon_names = TaxonName.all(
        :conditions => {:name => name, :lexicon => TaxonName::LEXICONS[:SCIENTIFIC_NAMES]}, 
        :limit => 10, :include => :taxon)
      unless params[:iconic_taxa].blank?
        taxon_names.reject {|tn| params[:iconic_taxa].include?(tn.taxon.iconic_taxon_id)}
      end
      taxon_name = taxon_names.detect{|tn| tn.is_valid?} || taxon_names.first
      scope = scope.of(taxon_name.try(:taxon) || false)
    end
    scope = scope.by(params[:user_id]) if params[:user_id]
    scope = scope.in_projects(params[:projects]) if params[:projects]
    scope = scope.near_place(params[:place_id]) if params[:place_id]
    
    # return the scope, we can use this for will_paginate calls like:
    # Observation.query(params).paginate()
    scope
  end
  # help_txt_for :species_guess, <<-DESC
  #   Type a name for what you saw.  It can be common or scientific, accurate 
  #   or just a placeholder. When you enter it, we'll try to look it up and find
  #   the matching species of higher level taxon.
  # DESC
  # 
  # instruction_for :place_guess, "Type the name of a place"
  # help_txt_for :place_guess, <<-DESC
  #   Enter the name of a place and we'll try to find where it is. If we find
  #   it, you can drag the map marker around to get more specific.
  # DESC
  
  def to_s
    "<Observation #{self.id}: #{to_plain_s}>"
  end
  
  def to_plain_s(options = {})
    s = self.species_guess.blank? ? 'something' : self.species_guess
    if options[:verb]
      s += options[:verb] == true ? " observed" : " #{options[:verb]}"
    end
    unless self.place_guess.blank? || options[:no_place_guess]
      s += " in #{self.place_guess}"
    end
    s += " on #{self.observed_on.to_s(:long)}" unless self.observed_on.blank?
    unless self.time_observed_at.blank? || options[:no_time]
      s += " at #{self.time_observed_at_in_zone.to_s(:plain_time)}"
    end
    s += " by #{self.user.login}" unless options[:no_user]
    s
  end
  
  # Used to help user debug their CSV files
  # TODO: move this to a helper
  def csv_record_to_s
    "Required Columns in order<br />"
      "Species Guess: #{self.species_guess}<br />"+
      "Observed On: #{self.observed_on}, which is interpreted as #{datetime}<br />"+
      "Description: #{self.description}<br />"+
      "Place Guess: #{self.place_guess}<br />"+
      "Optional Columns (Note: for any of these columns to be used in an observation, they must all be present)<br />"+
      "Latitude: #{self.latitude}<br />"+
      "Longitude: #{self.longitude}<br />"+
      "Location is exact: #{self.location_is_exact}"
  end

  #
  # Return a time from observed_on and time_observed_at
  #
  def datetime
    if self.observed_on
      if self.time_observed_at
        Time.mktime(self.observed_on.year, 
                    self.observed_on.month, 
                    self.observed_on.day, 
                    self.time_observed_at.hour, 
                    self.time_observed_at.min, 
                    self.time_observed_at.sec, 
                    self.time_observed_at.zone)
      else
        Time.mktime(self.observed_on.year, 
                    self.observed_on.month, 
                    self.observed_on.day)
      end
    end
  end
  
  # Return time_observed_at in the observation's time zone
  def time_observed_at_in_zone
    self.time_observed_at.in_time_zone(self.time_zone)
  end
  
  #
  # Set all the time fields based on the contents of observed_on_string
  #
  def munge_observed_on_with_chronic
    return true if observed_on_string.blank?
    date_string = observed_on_string.strip
    if parsed_time_zone = ActiveSupport::TimeZone::CODES[date_string[/\s([A-Z]{3,})$/, 1]]
      date_string = observed_on_string.sub(/\s([A-Z]{3,})$/, '')
      self.time_zone = parsed_time_zone.name if observed_on_string_changed?
    end
    
    # Set the time zone appropriately
    old_time_zone = Time.zone
    Time.zone = time_zone || user.time_zone
    Chronic.time_class = Time.zone
    
    begin
      # Start parsing...
      return true unless t = Chronic.parse(date_string)
    
      # Re-interpret future dates as being in the past
      if t > Time.now
        t = Chronic.parse(date_string, :context => :past)  
      end
    
      self.observed_on = t.to_date
    
      # try to determine if the user specified a time by ask Chronic to return
      # a time range. Time ranges less than a day probably specified a time.
      if tspan = Chronic.parse(date_string, :context => :past, 
                                                      :guess => false)
        # If tspan is less than a day and the string wasn't 'today', set time
        if tspan.width < 86400 && date_string.strip.downcase != 'today'
          self.time_observed_at = t
        else
          self.time_observed_at = nil
        end
      end
    rescue RuntimeError
      errors.add(:observed_on, 
        "was not recognized, some working examples are: yesterday, 3 years " +
        "ago, 5/27/1979, 1979-05-27 05:00. " +
        "(<a href='http://chronic.rubyforge.org/'>others</a>)")
      return
    end
    
    # don't store relative observed_on_strings, or they will change
    # every time you save an observation!
    if date_string =~ /today|yesterday|ago|last|this|now|monday|tuesday|wednesday|thursday|friday|saturday|sunday/i
      self.observed_on_string = self.observed_on.to_s
      if self.time_observed_at
        self.observed_on_string = self.time_observed_at.strftime("%Y-%m-%d %H:%M:%S")
      end
    end
    
    # Set the time zone back the way it was
    Time.zone = old_time_zone
    true
  end
  
  #
  # Adds, updates, or destroys the identification corresponding to the taxon
  # the user selected.
  #
  def update_identifications_after_save
    return true if @skip_identifications
    owners_ident = identifications.first(:conditions => {:user_id => self.user_id})
    owners_ident.skip_observation = true if owners_ident
    
    # If there's a taxon we need to make ure the owner's ident agrees
    if taxon
      # If the owner doesn't have an identification for this obs, make one
      unless owners_ident
        owners_ident = identifications.build(:user => user, :taxon => taxon)
        owners_ident.skip_observation = true
        owners_ident.skip_update = true
        owners_ident.save
      end
      
      # If the obs taxon and the owner's ident don't agree, make them
      if owners_ident.taxon_id != taxon_id
        owners_ident.update_attributes(:taxon_id => taxon_id)
      end
    
    # If there's no taxon, we should destroy the owner's ident
    elsif owners_ident
      owners_ident.destroy
    end
    
    true
  end
  
  #
  # Update the user's lists with changes to this observation's taxon
  #
  # If the observation is the last_observation in any of the user's lists,
  # then the last_observation should be reset to another observation.
  #
  def refresh_lists
    return if @skip_refresh_lists
    
    # Update the observation's current taxon and/or a previous one that was
    # just removed/changed
    target_taxa = [
      taxon, 
      Taxon.find_by_id(@old_observation_taxon_id)
    ].compact.uniq
    
    # Don't refresh all the lists if nothing changed
    return if target_taxa.empty?
    
    List.send_later(:refresh_for_user, self.user, :taxa => target_taxa.map(&:id), :skip_update => true)
    project_observations.each do |po|
      Project.send_later(:refresh_project_list, po.project_id, 
        :taxa => target_taxa.map(&:id), :add_new_taxa => true)
    end
    
    # Reset the instance var so it doesn't linger around
    @old_observation_taxon_id = nil
    true
  end
  
  # Because it has to be slightly different, in that the taxon of a destroyed
  # obs shouldn't be removed by default from life lists (maybe you've seen it
  # in the past, but you don't have any other obs), but those listed_taxa of
  # this taxon should have their last_observation reset.
  #
  def refresh_lists_after_destroy
    return if @skip_refresh_lists
    return unless taxon

    List.send_later(:refresh_for_user, self.user, :taxa => [taxon], :add_new_taxa => false)
  end
  
  #
  # Preserve the old taxon id if the taxon has changed so we know to update
  # that taxon in the user's lists after_save
  #
  def keep_old_taxon_id
    @old_observation_taxon_id = taxon_id_was if taxon_id_changed?
  end
  
  #
  # This is the hook used to check each observation to see if it may apply
  # to a system based goal. It does so by collecting all of the user's
  # current goals, including global goals and checking to see if the
  # observation passes each rule established by the goal. If it does, the
  # goal is recorded as a contribution in the goal_contributions table.
  #
  def update_goal_contributions
    user.goal_participants_for_incomplete_goals.each do |participant|
      participant.goal.validate_and_add_contribution(self, participant)
    end
    true
  end
  
  
  #
  # Remove any instructional text that may have been submitted with the form.
  #
  def scrub_instructions_before_save
    self.attributes.each do |attr_name, value|
      if Observation.instructions[attr_name.to_sym] and value and
        Observation.instructions[attr_name.to_sym] == value
        write_attribute(attr_name.to_sym, nil)
      end
    end
  end
  
  #
  # Set the iconic taxon if it hasn't been set
  #
  def set_iconic_taxon
    return unless self.taxon_id_changed?
    if taxon
      self.iconic_taxon_id ||= taxon.iconic_taxon_id
    else
      self.iconic_taxon_id = nil
    end
  end
  
  #
  # Trim whitespace around species guess
  #
  def strip_species_guess
    self.species_guess.strip! unless species_guess.nil?
    true
  end
  
  #
  # Set the time_zone of this observation if not already set
  #
  def set_time_zone
    self.time_zone = user.time_zone if user && time_zone.blank?
    self.time_zone = Time.zone if time_zone.blank? && !time_observed_at.blank?
    self.time_zone = nil if time_zone.blank?
    true
  end

  #
  # Cast lat and lon so they will (hopefully) pass the numericallity test
  #
  def cast_lat_lon
    self.latitude = latitude.to_f unless latitude.blank?
    self.longitude = longitude.to_f unless longitude.blank?
    true
  end  

  #
  # Force time_observed_at into the time zone
  #
  def set_time_in_time_zone
    return unless time_observed_at && time_zone && (time_observed_at_changed? || time_zone_changed?)
    
    # Render the time as a string
    time_s = time_observed_at_before_type_cast
    unless time_s.is_a? String
      time_s = time_observed_at_before_type_cast.strftime("%Y-%m-%d %H:%M:%S")
    end
    
    # Get the time zone offset as a string and append it
    offset_s = Time.parse(time_s).in_time_zone(time_zone).formatted_offset(false)
    time_s += " #{offset_s}"
    
    self.time_observed_at = Time.parse(time_s)
  end
  
  
  def lsid
    "lsid:inaturalist.org:observations:#{id}"
  end
  
  def component_cache_key(options = {})
    Observation.component_cache_key(id, options)
  end
  
  def self.component_cache_key(id, options = {})
    key = "obs_comp_#{id}"
    key += "_"+options.map{|k,v| "#{k}-#{v}"}.join('_') unless options.blank?
    key
  end
  
  def num_identifications_by_others
    identifications.select{|i| i.user_id != user_id}.size
  end
  
  ##### Rules ###############################################################
  #
  # This section contains all of the rules that can be used for list creation
  # or goal completion
  
  class << self # this just prevents me from having to write def self.*
    
    # Written for the Goals framework.
    # Accepts two parameters, the first is 'thing' from GoalRule,
    # the second is an array created when the GoalRule splits on pipes "|"
    def within_the_first_n_contributions?(observation, args)
      return false unless observation.instance_of? self
      return true if count <= args[0].to_i
      find(:all,
           :select => "id",
           :order => "created_at ASC",
           :limit => args[0]).include?(observation)
    end
  end

  #
  # Checks whether this observation has been flagged
  #
  def flagged?
    self.flags.select { |f| not f.resolved? }.size > 0
  end
  
  protected
  
  ##### Validations #########################################################
  #
  # Make sure the observation is not in the future.
  #
  def must_be_in_the_past

    unless observed_on.nil? || observed_on <= Date.today
      errors.add(:observed_on, "can't be in the future")
    end
    true
  end

  #
  # Make sure the observation resolves to a single day.  Right now we don't
  # store ambiguity...
  #
  def must_not_be_a_range
    return if observed_on_string.blank?
    
    is_a_range = false
    begin  
      if tspan = Chronic.parse(observed_on_string, :context => :past, :guess => false)
        is_a_range = true if tspan.width.seconds > 1.day.seconds
      end
    rescue RuntimeError
      errors.add(:observed_on, 
        "was not recognized, some working examples are: yesterday, 3 years " +
        "ago, 5/27/1979, 1979-05-27 05:00. " +
        "(<a href='http://chronic.rubyforge.org/'>others</a>)"
      ) 
      return
    end
    
    # Special case: dates like '2004', which ordinarily resolve to today at 
    # 8:04pm
    observed_on_int = observed_on_string.gsub(/[^\d]/, '').to_i
    if observed_on_int > 1900 && observed_on_int <= Date.today.year
      is_a_range = true
    end
    
    if is_a_range
      errors.add(:observed_on, "must be a single day, not a range")
    end
  end
  
  def set_taxon_from_species_guess
    return true unless species_guess_changed? && taxon_id.blank?
    return true if species_guess.blank?
    taxon_names = TaxonName.all(:conditions => ["name = ?", species_guess.strip], :limit => 5, :include => :taxon)
    return true if taxon_names.blank?
    if taxon_names.size == 1
      self.taxon_id = taxon_names.first.taxon_id 
      return true
    end
    sorted = Taxon.sort_by_ancestry(taxon_names.map(&:taxon))
    return true unless sorted.first.ancestor_of?(sorted.last)
    self.taxon_id = sorted.first.id
    true
  end
  
  def set_latlon_from_place_guess
    return true unless latitude.blank? && longitude.blank?
    return true if place_guess.blank?
    if matches = place_guess.strip.match(/(-?\d+(?:\.\d+)?),\s?(-?\d+(?:\.\d+)?)/)
      self.latitude, self.longitude = matches[1..2]
    end
    true
  end
  
  # Not *entirely* sure this is the best strategy...
  def set_positional_accuracy
    if (latitude_changed? || longitude_changed?) && !positional_accuracy_changed?
      self.positional_accuracy = nil
    end
    true
  end
  
  # I'm not psyched about having this stuff here, but it makes generating 
  # more compact JSON a lot easier.
  include ObservationsHelper
  include ActionView::Helpers::SanitizeHelper
  include ActionView::Helpers::TextHelper
  include ActionController::UrlWriter
  
  def image_url
    observation_image_url(self)
  end
  
  def short_description
    short_observation_description(self)
  end
  
  def scientific_name
    taxon.scientific_name.name if taxon && taxon.scientific_name
  end
  
  def common_name
    taxon.common_name.name if taxon && taxon.common_name
  end
  
  def url
    observation_url(self, ActionMailer::Base.default_url_options)
  end
  
  def user_login
    user.login
  end
  
  private
  
  # Required for use of the sanitize method in
  # ObservationsHelper#short_observation_description
  def self.white_list_sanitizer
    @white_list_sanitizer ||= HTML::WhiteListSanitizer.new
  end
end
