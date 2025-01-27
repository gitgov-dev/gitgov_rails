# frozen_string_literal: true

module StubObjectStorage
  def stub_packages_object_storage(**params)
    stub_object_storage_uploader(config: ::Gitlab.config.packages.object_store,
                                  uploader: ::Packages::PackageFileUploader,
                                  remote_directory: 'packages',
                                  **params)
  end

  def stub_dependency_proxy_object_storage(**params)
    stub_object_storage_uploader(config: ::Gitlab.config.dependency_proxy.object_store,
                                  uploader: ::DependencyProxy::FileUploader,
                                  remote_directory: 'dependency_proxy',
                                  **params)
  end

  def stub_object_storage_pseudonymizer
    stub_object_storage(connection_params: Pseudonymizer::Uploader.object_store_credentials,
                        remote_directory: Pseudonymizer::Uploader.remote_directory)
  end

  def stub_object_storage_uploader(
        config:,
        uploader:,
        remote_directory:,
        enabled: true,
        proxy_download: false,
        background_upload: false,
        direct_upload: false
  )
    allow(config).to receive(:enabled) { enabled }
    allow(config).to receive(:proxy_download) { proxy_download }
    allow(config).to receive(:background_upload) { background_upload }
    allow(config).to receive(:direct_upload) { direct_upload }

    return unless enabled

    stub_object_storage(connection_params: uploader.object_store_credentials,
                        remote_directory: remote_directory)
  end

  def stub_object_storage(connection_params:, remote_directory:)
    Fog.mock!

    ::Fog::Storage.new(connection_params).tap do |connection|
      connection.directories.create(key: remote_directory)

      # Cleanup remaining files
      connection.directories.each do |directory|
        directory.files.map(&:destroy)
      end
    rescue Excon::Error::Conflict
    end
  end

  def stub_artifacts_object_storage(**params)
    stub_object_storage_uploader(config: Gitlab.config.artifacts.object_store,
                                 uploader: JobArtifactUploader,
                                 remote_directory: 'artifacts',
                                 **params)
  end

  def stub_external_diffs_object_storage(uploader = described_class, **params)
    stub_object_storage_uploader(config: Gitlab.config.external_diffs.object_store,
                                 uploader: uploader,
                                 remote_directory: 'external-diffs',
                                 **params)
  end

  def stub_lfs_object_storage(**params)
    stub_object_storage_uploader(config: Gitlab.config.lfs.object_store,
                                 uploader: LfsObjectUploader,
                                 remote_directory: 'lfs-objects',
                                 **params)
  end

  def stub_package_file_object_storage(**params)
    stub_object_storage_uploader(config: Gitlab.config.packages.object_store,
                                 uploader: ::Packages::PackageFileUploader,
                                 remote_directory: 'packages',
                                 **params)
  end

  def stub_uploads_object_storage(uploader = described_class, **params)
    stub_object_storage_uploader(config: Gitlab.config.uploads.object_store,
                                 uploader: uploader,
                                 remote_directory: 'uploads',
                                 **params)
  end

  def stub_terraform_state_object_storage(uploader = described_class, **params)
    stub_object_storage_uploader(config: Gitlab.config.terraform_state.object_store,
                                 uploader: uploader,
                                 remote_directory: 'terraform_state',
                                 **params)
  end

  def stub_object_storage_multipart_init(endpoint, upload_id = "upload_id")
    stub_request(:post, %r{\A#{endpoint}tmp/uploads/[a-z0-9-]*\?uploads\z})
      .to_return status: 200, body: <<-EOS.strip_heredoc
        <?xml version="1.0" encoding="UTF-8"?>
        <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Bucket>example-bucket</Bucket>
          <Key>example-object</Key>
          <UploadId>#{upload_id}</UploadId>
        </InitiateMultipartUploadResult>
      EOS
  end
end
