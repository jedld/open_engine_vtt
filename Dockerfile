FROM ruby:3.2.0
RUN mkdir -p /usr/app
RUN gem install bundler
COPY . /usr/app
WORKDIR /usr/app
RUN bundle
EXPOSE 4567
CMD ruby app.rb
