module API
  class Namespaces < Grape::API
    include PaginationParams

    before { authenticate! }

    resource :namespaces do
      desc 'Get a namespaces list' do
        success Entities::Namespace
      end
      params do
        optional :search, type: String, desc: "Search query for namespaces"
        use :pagination
      end
      get do
        namespaces = current_user.admin ? Namespace.all : current_user.namespaces

        namespaces = namespaces.search(params[:search]) if params[:search].present?

        present paginate(namespaces), with: Entities::Namespace, current_user: current_user
      end

      desc 'Get a namespace by ID' do
        success Entities::Namespace
      end
      params do
        requires :id, type: Integer, desc: "Namespace's ID"
      end
      get ':id' do
        namespace = Namespace.find(params[:id])
        authenticate_get_namespace!(namespace)

        present namespace, with: Entities::Namespace, current_user: current_user
      end
    end

    helpers do
      def authenticate_get_namespace!(namespace)
        return if current_user.admin?
        forbidden!('No access granted') unless user_can_access_namespace?(namespace)
      end

      def user_can_access_namespace?(namespace)
        namespace.has_owner?(current_user)
      end
    end
  end
end
