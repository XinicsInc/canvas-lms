#!/bin/bash
source script/common/utils/common.sh
source script/common/os/linux/impl.sh
source script/common/utils/dory_setup.sh
#dependencies='docker,docker-compose 1.20.0'
# 이제 docker-compose 라는 패키지나 명령어는 존재하지 않는다. 그냥 의존성 체크는 하지 말라고
# 하자.
dependencies=
# 이제 docker-compose 라는 패키지나 명령어는 존재하지 않는다.
#DOCKER_COMMAND="docker-compose"
DOCKER_COMMAND="docker compose"

message "It looks like you're using Linux. Let's set that up."

# rootless docker 설치를 했기 때문에, 그냥 service/systemctl 명령어를 사용할 수 없다.
# 얘보고 시작하라고 안해도 되니까 주석 처리.
#set_service_util

# 의존성 목록도 비워두긴 했지만 그냥 주석처리까지 해놨다.
#check_dependencies

# dory 는 설치하면 좋을지도 모르겠는데(reverse proxy 랑 https 처리를 해준다고)
# 지금은 잘 모르겠으니까 주석 처리.
#check_for_dory

# 이것도 rootless mode는 이렇게 시작하는 게 아니니까 주석 처리.
#start_docker_daemon

# 이미 rootless mode 로 해놨다고 위험한 짓 하지마
#setup_docker_as_nonroot

# 역시 dory 는 주석 처리.
#[[ ${skip_dory:-n} == 'y' ]] || start_dory
