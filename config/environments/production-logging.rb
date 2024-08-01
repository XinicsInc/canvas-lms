# frozen_string_literal: true

# 이 파일은 같은 폴더의 production.rb 파일 끝에서 로드된다.
#
# 순서상 config/application.rb 에서 CanvasRails::Application 클래스 초기화가 된 후
# config/environments/production.rb 가 실행된다.
#
# 그 뒤에 config.before_initialize 등의 콜백들(config/initializers 폴더)이
# 실행되는 순서라고 한다.
# 실험을 해보니 config.before_initialize 블록에서 logger 를 변경해도 효과가 없어서
# environments 에서 변경하고 있다.

environment_configuration(defined?(config) && config) do |config|

  # 컨테이너 환경에서 실행될 때 로그를 컨테이너 로그(docker logs)로 보내기 위함.
  #
  # 특정 환경변수가 설정되어 있을 때에만 효과가 생기도록 해놔서,
  # 일반 운영 환경에는 영향을 주지 않을 것이다.
  #
  # delayed_job 은 컨테이너로 실행 시 이 설정만으로 충분하다.
  #
  # passenger(Apache mod_passenger)로 실행되는 웹 어플리케이션은 stdout 으로
  # 보내지는 내용을 아파치의 기본 ErrorLog 파일에 기록하는 방식이다.
  # 그래서 아파치 설정에서도 ErrorLog 기록 위치를 stdout 이나 stderr 로 변경해야
  # 최종적으로 컨테이너 로그(docker logs)에서 어플리케이션 로그를 볼 수 있다.
  if ENV["RAILS_LOG_TO_STDOUT"].to_s.downcase == "true"
    # 디버그용
    puts "RAILS_LOG_TO_STDOUT is true, #{__FILE__}"

    logger = ActiveSupport::Logger.new(STDOUT)
    logger.formatter = proc do |severity, datetime, progname, msg|
      "#{datetime}: #{severity} - #{msg}\n"
    end

    log_level_sym = ActiveSupport::Logger.const_get(config.log_level.to_s.upcase)
    config.logger = ActiveSupport::TaggedLogging.new(logger)
    config.logger.level = log_level_sym
  end

end
