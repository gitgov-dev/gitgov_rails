FROM gitlab/gitlab-ce:latest

RUN echo "------ before replacement ------"
RUN ls -la /opt/gitlab/embedded/service/

RUN rm -r /opt/gitlab/embedded/service/gitlab-rails

RUN echo "------ after removing ------"
RUN ls -la /opt/gitlab/embedded/service/

RUN mkdir /opt/gitlab/embedded/service/gitlab-rails
COPY ./ /opt/gitlab/embedded/service/gitlab-rails/

# Configure gitlab
RUN mkdir -p /opt/gitlab/embedded/service/gitlab-rails/public/uploads
RUN mkdir /opt/gitlab/embedded/service/gitlab-rails/db
#RUN touch /var/opt/gitlab/gitlab-rails/REVISION
RUN touch /opt/gitlab/embedded/service/gitlab-rails/REVISION

RUN echo "------ after replacement ------"
RUN ls -la /opt/gitlab/embedded/service/
