require __DIR__ + 'associations/many_to_one'
require __DIR__ + 'associations/one_to_many'
require __DIR__ + 'associations/many_to_many'
require __DIR__ + 'associations/one_to_one'

module DataMapper
  module Associations
    def self.extended(base)
      base.extend ManyToOne
      base.extend OneToMany
      base.extend ManyToMany
      base.extend OneToOne
    end

    def relationships
      @relationships ||= {}
    end

    def n
      1.0/0
    end
    
    #
    # A shorthand, clear syntax for defining resource relationships.
    # 
    # Basic Usage Examples...
    #
    # * has 1..n, :friends    # one_to_many :friends
    # * has 1, :friend        # one_to_one, :friend
    # * has n..1, :friends    # many_to_one, :friends
    # * has n..n, :friends    # many_to_many, :friends
    #
    # Advanced Usage Examples...
    #
    # * has 1..3, :friends                  # one_to_many :friends, :min => 3, :max => 3
    # * has 1..2, :friends, :max=>5         # one_to_many :friends, :min => 2, :max => 5
    # * has 3, :friends                     # one_to_many :friends, :min => 3, :max => 3
    # * has 3..3, :friends                  # many_to_many :friends, :left=>{:min=>3, :max=>3}, :right=>{:min=>3, :max=>3}
    # * has 1, :friend, :class_name=>'User' # one_to_one :friend, :class_name => 'User'
    #
    # * <tt>contraints</tt> - constraints can be defined as either a fixed number, Infinity or a range
    #
    def has(cardinality, name, options = {})
      case cardinality
        when Range
          left, right = cardinality.first, cardinality.last
          case 1
            when left                       #1..n or 1..2
              one_to_many(name, extract_min_max(right).merge(options))
            when right                      # n..1 or 2..1
              many_to_one(name, extract_min_max(left).merge(options))
            else                            # n..n or 2..2
              many_to_many(name, extract_min_max(cardinality).merge(options))
          end
        when 1
          one_to_one(name, options)
        when Fixnum, Bignum, n              # n or 2 - shorthand form of 1..n or 1..2
          one_to_many(name, extract_min_max(cardinality).merge(options))
      end || raise(ArgumentError, "Cardinality #{cardinality.inspect} (#{cardinality.class}) not handled")
    end
    
    
  private 
  
    # A support method form converting numbers ranges or Infinity values into a {:min=>x, :max=>y} hash.
    #
    # * <tt>contraints</tt> - constraints can be defined as either a fixed number, Infinity or a range
    def extract_min_max(contraints)
      case contraints
        when Range
          left = extract_min_max(contraints.first)
          right = extract_min_max(contraints.last)
          conditions = {}
          conditions.merge!(:left=>left) if left.any?
          conditions.merge!(:right=>right) if right.any?
          conditions
        when Fixnum, Bignum
          {:min=>contraints, :max=>contraints}
        when n
          {}
      end || raise(ArgumentError, "Contraint #{contraints.inspect} (#{contraints.class}) not handled must be one of Range, Fixnum, Bignum, Infinity(n)")
    end
  end # module Associations
end # module DataMapper
