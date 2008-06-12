module DataMapper
  class Collection < LazyArray
    attr_reader :query

    def repository
      query.repository
    end

    def load(values)
      model = @inheritance_property_index && values && values.at(@inheritance_property_index) || self.model

      # TODO: think about moving the logic here into Model#load
      resource = nil

      if @key_property_indexes
        key_values = values.values_at(*@key_property_indexes)

        if resource = repository.identity_map_get(model, key_values)
          add(resource)

          return resource unless query.reload?
        else
          resource = model.allocate
          resource.instance_variable_set(:@new_record, false)

          @key_properties.zip(key_values).each do |property,key_value|
            resource.instance_variable_set(property.instance_variable_name, key_value)
          end

          repository.identity_map_set(resource)

          add(resource)
        end
      else
        resource = model.allocate
        resource.instance_variable_set(:@new_record, false)
        resource.readonly!

        add(resource)
      end

      @properties.zip(values).each do |property, value|
        value = property.custom? ? property.type.load(value, property) : property.typecast(value)
        resource.instance_variable_set(property.instance_variable_name, value)
        if [:load, :hash].include?(property.track)
          if property.track == :hash
            resource.original_values[property.name] = value.dup.hash unless resource.original_values.has_key?(property.name) rescue value.hash
          else
            resource.original_values[property.name] = value unless resource.original_values.has_key?(property.name)
          end
        end
      end

      resource
    end

    def reload(query = {})
      # TODO: turn query into a Query object

      query[:fields] ||= self.query.fields
      query[:fields]  |= @key_properties

      @query = self.query.merge(keys.merge(query))

      replace(all(:reload => true))
    end

    def get(*key)
      if loaded?
        # loop over the collection to find the matching resource
        detect { |resource| resource.key == key }
      elsif query.limit || query.offset > 0
        # current query is exclusive, find resource within the set

        # TODO: use a subquery to retrieve the collection and then match
        #   it up against the key.  This will require some changes to
        #   how subqueries are generated, since the key may be a
        #   composite key.  In the case of DO adapters, it means subselects
        #   like the form "(a, b) IN(SELECT a,b FROM ...)", which will
        #   require making it so the Query condition key can be a
        #   Property or an Array of Property objects

        # use the brute force approach until subquery lookups work
        lazy_load!
        get(*key)
      else
        # current query is all inclusive, lookup using normal approach
        conditions = Hash[ *@key_properties.zip(key).flatten ]
        first(conditions)
      end
    end

    def get!(*key)
      get(*key) || raise(ObjectNotFoundError, "Could not find #{model.name} with key #{key.inspect} in collection")
    end

    def all(query = {})
      if query.kind_of?(Hash)
        return self if query.empty?
        query = self.query.class.new(repository, model, query)
      end

      # TODO: if loaded?, and the query is the same as self.query,
      # then return self

      first_pos = self.query.offset + query.offset
      last_pos  = self.query.offset + self.query.limit if self.query.limit

      if limit = query.limit
        if last_pos.nil? || first_pos + limit < last_pos
          last_pos = first_pos + limit
        end
      end

      # return empty collection if outside range
      if last_pos && first_pos >= last_pos
        return empty_collection
      end

      query.update(:offset => first_pos)
      query.update(:limit => last_pos - first_pos) if last_pos

      repository.all(model, self.query.merge(query))
    end

    def first(*args)
      query = args.last.respond_to?(:merge) ? args.pop : {}

      # TODO: if loaded? and the passed-in query is a subset of
      #   self.query then delegate to super

      if args.any?
        all(query.merge(:limit => args.first))
      else
        all(query.merge(:limit => 1)).to_a.first
      end
    end

    def last(*args)
      reversed = reverse

      # TODO: if loaded? and the passed-in query is a subset of
      #   self.query then delegate to super

      # tell the collection to reverse the order of the
      # results coming out of the adapter
      reversed.query.add_reversed = !query.add_reversed?

      reversed.first(*args)
    end

    def at(offset)
      first(:offset => offset)
    end

    def slice(*args)
      raise ArgumentError, "must be 1 or 2 arguments, was #{args.size}" if args.size == 0 || args.size > 2

      return at(args.first) if args.size == 1 && args.first.kind_of?(Integer)

      if args.size == 2 && args.first.kind_of?(Integer) && args.last.kind_of?(Integer)
        offset, limit = args
      elsif args.size == 1 && args.first.kind_of?(Range)
        range  = args.first
        offset = range.first
        limit  = range.last - offset
        limit += 1 unless range.exclude_end?
      else
        raise ArgumentError, "arguments may be 1 or 2 Integers, or 1 Range object, was: #{args.inspect}"
      end

      all(:offset => offset, :limit => limit)
    end

    alias [] slice

    def reverse
      all(self.query.reverse)
    end

    def <<(resource)
      relate_resource(resource)
      super
    end

    def push(*resources)
      resources.each { |resource| relate_resource(resource) }
      super
    end

    def unshift(*resources)
      resources.each { |resource| relate_resource(resource) }
      super
    end

    def replace(other)
      if loaded?
        each { |resource| orphan_resource(resource) }
      end
      other.each { |resource| relate_resource(resource) }
      super
    end

    def pop
      orphan_resource(super)
    end

    def shift
      orphan_resource(super)
    end

    def delete(resource, &block)
      orphan_resource(super)
    end

    def delete_at(index)
      orphan_resource(super)
    end

    def clear
      if loaded?
        each { |resource| orphan_resource(resource) }
      end
      super
    end

    def create(attributes = {})
      resource = model.allocate
      resource.send(:initialize_with_attributes, default_attributes.merge(attributes))
      if repository.save(resource)
        self << resource
      end
      resource
    end

    def update(attributes = {})
      # TODO: update this to use bulk update once adapter API changes completed
      map do |resource|
        resource.attributes = attributes
        repository.save(resource)
      end.all?
    end

    def destroy
      # TODO: update this to use bulk destroy once adapter API changes completed
      success = map { |resource| repository.destroy(resource) }.all?
      clear
      success
    end

    def properties
      PropertySet.new(query.fields)
    end

    def relationships
      model.relationships(repository.name)
    end

    def default_attributes
      default_attributes = {}
      query.conditions.each do |tuple|
        operator, property, bind_value = *tuple

        next unless operator == :eql &&
          property.kind_of?(DataMapper::Property) &&
          ![ Array, Range ].any? { |k| bind_value.kind_of?(k) }
          !@key_properties.include?(property)

        default_attributes[property.name] = bind_value
      end
      default_attributes
    end

    protected

    def model
      query.model
    end

    private

    def initialize(query, &loader)
      raise ArgumentError, "+query+ must be a DataMapper::Query, but was #{query.class}", caller unless query.kind_of?(Query)

      @query      = query
      @properties = query.fields

      super()
      load_with(&loader)

      if inheritance_property = model.inheritance_property(repository.name)
        @inheritance_property_index = @properties.index(inheritance_property)
      end

      if (@key_properties = model.key(repository.name)).all? { |property| @properties.include?(property) }
        @key_property_indexes = @key_properties.map { |property| @properties.index(property) }
      end
    end

    def keys
      keys = {}

      if (entry_keys = map { |resource| resource.key }).any?
        @key_properties.zip(entry_keys.transpose).each do |property,values|
          keys[property] = values.size == 1 ? values[0] : values
        end
      end

      keys
    end

    def empty_collection
      # TODO: figure out how to create an empty collection
      #   - must have a null query object.. i.e. should not be possible
      #     to get any rows from it
      []
    end

    def add(resource)
      query.add_reversed? ? unshift(resource) : push(resource)
    end

    def relate_resource(resource)
      resource.collection = self if resource
      resource
    end

    def orphan_resource(resource)
      resource.collection = nil if resource && resource.collection == self
      resource
    end

    def method_missing(method_name, *args)
      if relationships[method_name]
        map { |e| e.send(method_name) }.flatten.compact
      else
        super
      end
    end
  end # class Collection
end # module DataMapper