FROM gitlab/gitlab-ce:latest

RUN echo "------ before replacement ------"
RUN ls -la /opt/gitlab/embedded/service/

RUN rm -r /opt/gitlab/embedded/service/gitlab-rails

RUN echo "------ after removing ------"
RUN ls -la /opt/gitlab/embedded/service/

RUN mkdir /opt/gitlab/embedded/service/gitlab-rails
COPY ./ /opt/gitlab/embedded/service/gitlab-rails/

# Configure gitlab
RUN mkdir -p /opt/gitlab/embedded/service/gitlab-rails/public
RUN mkdir /opt/gitlab/embedded/service/gitlab-rails/db
#RUN touch /var/opt/gitlab/gitlab-rails/REVISION
RUN touch /opt/gitlab/embedded/service/gitlab-rails/REVISION

# Run bundle install
RUN cd /opt/gitlab/embedded/service/gitlab-rails \
 && gem install bundler -v 1.15.4 \
 && printf "\n#Custom gems\n\ngem 'omniauth-ely', '~> 0.1.0'\n" >> Gemfile \
 && rm -rf vendor/bundle \
 && bundler install


RUN echo "------ after replacement ------"
RUN ls -la /opt/gitlab/embedded/service/
