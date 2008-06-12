module DataMapper
  module Associations
    class RelationshipChain < Relationship
      OPTIONS = [
        :repository_name, :near_relationship_name, :remote_relationship_name,
        :child_model_name, :parent_model_name, :parent_key, :child_key,
        :min, :max
      ]

      undef_method :get_parent
      undef_method :attach_parent

      def child_model
        near_relationship.child_model
      end

      # @private
      def get_children(parent, options = {}, finder = :all, *args)
        query = @query.merge(options).merge(child_key.to_query(parent_key.get(parent)))

        query[:links] = links

        DataMapper.repository(parent.repository.name) do
          results = grandchild_model.send(finder, *(args << query))
          # FIXME: remove the need for the uniq.freeze
          finder == :all ? results.uniq.freeze : results
        end
      end

      private

      def near_relationship
        parent_model.relationships[@near_relationship_name]
      end

      def links
        if remote_relationship.kind_of?(RelationshipChain)
          remote_relationship.instance_eval { links } + [remote_relationship.instance_eval { near_relationship } ]
        else
          [ remote_relationship ]
        end
      end

      def remote_relationship
        near_relationship.child_model.relationships[@remote_relationship_name] ||
          near_relationship.child_model.relationships[@remote_relationship_name.to_s.singularize.to_sym]
      end

      def grandchild_model
        find_const(@child_model_name)
      end

      def initialize(options)
        if (missing_options = options.keys - OPTIONS).any?
          raise ArgumentError, "The options #{missing_options * ', '} are required"
        end

        @repository_name          = options.fetch(:repository_name)
        @near_relationship_name   = options.fetch(:near_relationship_name)
        @remote_relationship_name = options.fetch(:remote_relationship_name)
        @child_model_name         = options.fetch(:child_model_name)
        @parent_model_name        = options.fetch(:parent_model_name)
        @parent_properties        = options.fetch(:parent_key)
        @child_properties         = options.fetch(:child_key)

        @name        = near_relationship.name
        @query       = options.reject{ |key,val| OPTIONS.include?(key) }
        @extra_links = []
        @options     = options
      end
    end # class Relationship
  end # module Associations
end # module DataMapper