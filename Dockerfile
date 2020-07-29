FROM gitlab/gitlab-ce:latest

RUN echo "------ before replacement ------"
RUN ls -la /opt/gitlab/embedded/service/

RUN rm -r /opt/gitlab/embedded/service/gitlab-rails

RUN echo "------ after removing ------"
RUN ls -la /opt/gitlab/embedded/service/

RUN mkdir /opt/gitlab/embedded/service/gitlab-rails
COPY ./ /opt/gitlab/embedded/service/gitlab-rails/

RUN mkdir /opt/gitlab/embedded/serivce/gitlab-rails/public/uploads

RUN echo "------ after replacement ------"
RUN ls -la /opt/gitlab/embedded/service/
