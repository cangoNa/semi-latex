# コンテナ名
NAME := latex-container

# DockerHubのリポジトリ名
# make get-imageの取得先
DOCKER_REPOSITORY := taka0628/semi-latex
PYTHON_REPOSITORY := python:3.10-alpine
# texfileの自動整形をする
# yes -> true, no -> true以外
AUTO_FORMAT := true

DOCKER_USER_NAME := guest
DOCKER_HOME_DIR := /home/guest
CURRENT_PATH := $(shell pwd)

STYLE_DIR := internal/container/style
SCRIPTS_DIR := internal/local
INTERAL_FILES := $(shell ls ${STYLE_DIR})
INTERAL_FILES += $(shell ls ${SCRIPTS_DIR})

ARCH := $$(uname -m)

# ビルドするtexファイルのディレクトリ
# fはTEX_FILE_PATHのエイリアス
f :=
ifneq (${new},)
	f := ${new}
endif

TEX_FILE_PATH := ${f}
ifeq (${TEX_FILE_PATH},)
	TEX_FILE_PATH := $$(bash ${SCRIPTS_DIR}/search-main.sh)
endif
TEX_FILE_NAME := $$(echo ${TEX_FILE_PATH} | rev | cut -d '/' -f 1 | rev)
TEX_DIR_PATH := $$(echo ${TEX_FILE_PATH} | sed -e "s@${TEX_FILE_NAME}@@" -e "s@$$(pwd)/@@")

TEX_DIR := $$(echo ${TEX_DIR_PATH} | rev | cut -d "/" -f 2 | rev)
FOCUS_FILE_NAME := $$(basename ${f})

SHELL := /bin/bash

.PHONY: run
.PHONY: lint
.PHONY: bash

# make実行時に実行されるmakeコマンドの設定
.DEFAULT_GOAL := run

# LaTeXのビルド
run:
	bash internal/local/tesBuild.tex

# TextLint
lint:
	@make _preExec -s
	@- docker container exec --user root ${NAME} /bin/bash -c "textlint ${TEX_DIR}/${TEX_FILE_NAME} > ${TEX_DIR}/lint.txt"
	- docker container exec --user root -t --env TEX_PATH="$$(readlink -f ${TEX_DIR})" ${NAME} /bin/bash -c "cd ${TEX_DIR} && bash lint-formatter.sh ${TEX_FILE_PATH}"
	@- docker container exec --user root ${NAME} /bin/bash -c "cd ${TEX_DIR} && rm -f lint.txt"
	@make _postExec -s

lint-fix:
	@make _preExec -s
	@- docker container exec --user root -t ${NAME} /bin/bash -c "textlint --fix ${TEX_DIR}/${TEX_FILE_NAME}"
	@make _postExec -s

# 差分を色付けして出力
old :=
new :=
diff:
	@if [[ $$(docker ps -a | grep -c ${NAME}) -eq 0 ]]; then\
		docker container run \
		-it \
		--rm \
		-d \
		--name ${NAME} \
		${NAME}:${ARCH};\
	fi
	@if [[ -z ${old} ]] || [[ -z ${new} ]]; then\
		exit 1;\
	fi
	-docker container cp ${old} ${NAME}:${DOCKER_HOME_DIR}
	-docker container cp ${new} ${NAME}:${DOCKER_HOME_DIR}
	- docker container exec --user root ${NAME} /bin/bash -c "latexdiff --graphics-markup=none -e utf8 -t CFONT $$(basename ${old}) $$(basename ${new})  > diff.tex"
	make _preExec TEX_DIR_PATH=$$(dirname ${new}) TEX_DIR=$$(dirname ${new} | rev | cut -d "/" -f 1 | rev)
	- docker container exec --user root ${NAME} /bin/bash -c "rm ${DOCKER_HOME_DIR}/${TEX_DIR}/*.tex"
	- docker container exec --user root ${NAME} /bin/bash -c "cp ${DOCKER_HOME_DIR}/diff.tex ${DOCKER_HOME_DIR}/${TEX_DIR}"
	- docker container exec --user root ${NAME} /bin/bash -c "cd ${DOCKER_HOME_DIR}/${TEX_DIR} && make all && make all && make all"
	-docker container cp ${NAME}:${DOCKER_HOME_DIR}/${TEX_DIR}/diff.pdf ${TEX_DIR_PATH}diff.pdf
	-docker container cp ${NAME}:${DOCKER_HOME_DIR}/${TEX_DIR}/diff.log ${TEX_DIR_PATH}diff.log
	-docker container exec --user root ${NAME}  /bin/bash -c "rm -rf ${DOCKER_HOME_DIR}/${TEX_DIR} ${DOCKER_HOME_DIR}/*.tex"

# sampleをビルド
run-sample:
	make run f=sample/semi-sample/semi.tex -s

# コンテナのビルド
docker-build:
	make docker-stop -s
	DOCKER_BUILDKIT=1 docker image build -t ${NAME}:x86_64 .
	make _postBuild -s

docker-buildforArm:
	make docker-stop -s
	DOCKER_BUILDKIT=1 docker image build -t ${NAME}:arm64 -f Dockerfile.arm64 .
	make _postBuild -s


# キャッシュを使わずにビルド
docker-rebuild:
	make docker-stop -s
	DOCKER_BUILDKIT=1 docker image build -t ${NAME}:x86_64 \
	--pull \
	--force-rm=true \
	--no-cache=true .
	make _postBuild -s

docker-rebuildforArm:
	make docker-stop -s
	DOCKER_BUILDKIT=1 docker image build -t ${NAME}:arm64 \
	-f Dockerfile.arm64 \
	--pull \
	--force-rm=true \
	--no-cache=true .
	make _postBuild -s

# dockerのリソースを開放
docker-clean:
	docker system prune -f

# dockerコンテナを停止
docker-stop:
	@if [[ $$(docker container ls -a | grep -c "${NAME}") -ne 0 ]]; then\
		docker container kill ${NAME};\
		echo "コンテナを停止";\
		sync;\
	fi
	@docker container ls -a

# コンテナを開きっぱなしにする
# リモートアクセス用
bash:
	make _preExec -s
	-docker container exec -it ${NAME} bash

# root権限で起動中のコンテナに接続
# aptパッケージのインストールをテストする際に使用
root:
	make _preExec -s
	-docker container exec -it --user root ${NAME} bash
	make _postExec -s

# コンテナ実行する際の前処理
# 起動，ファイルのコピーを行う
_preExec:
	@if [[ $$(docker ps -a | grep -c ${NAME}) -eq 0 ]]; then\
		docker container run \
		-it \
		--rm \
		-d \
		--name ${NAME} \
		${NAME}:${ARCH};\
	fi
	-docker container cp ${TEX_DIR_PATH} ${NAME}:${DOCKER_HOME_DIR}
	-docker container exec --user root ${NAME}  /bin/bash -c "cp -n ${DOCKER_HOME_DIR}/internal/style/* ${DOCKER_HOME_DIR}/${TEX_DIR} \
		&& cp -n ${DOCKER_HOME_DIR}/internal/scripts/* ${DOCKER_HOME_DIR}/${TEX_DIR}"

# コンテナ終了時の後処理
# コンテナ内のファイルをローカルへコピー，コンテナの削除を行う
_postExec:
	-docker container exec --user root ${NAME}  bash -c "cd ${DOCKER_HOME_DIR}/${TEX_DIR} && rm ${INTERAL_FILES} "
	-docker container exec --user root ${NAME} /bin/bash -c "rm -f \
		$$(docker container exec --user root ${NAME} /bin/bash -c  "find . -name "*.xbb" -type f" | sed -z 's/\n/ /g' )"
# ビルド中にローカルのtexファイルが更新されている場合，コンテナ内のtexファイルを上書きしない
	@if [[ $$(date -r ${TEX_FILE_PATH} +%s) -lt $$(docker container exec --user root ${NAME} /bin/bash -c "date -r ${DOCKER_HOME_DIR}/${TEX_DIR}/${TEX_FILE_NAME} +%s") ]]; then\
		docker container cp ${NAME}:${DOCKER_HOME_DIR}/${TEX_DIR} ${TEX_DIR_PATH}../ ;\
	else\
		docker container exec --user root ${NAME} bash -c "rm ${DOCKER_HOME_DIR}/${TEX_DIR}/${TEX_FILE_NAME}" ;\
		docker container cp ${NAME}:${DOCKER_HOME_DIR}/${TEX_DIR} ${TEX_DIR_PATH}../ ;\
	fi
	-docker container exec --user root ${NAME}  /bin/bash -c "rm -rf ${DOCKER_HOME_DIR}/${TEX_DIR} "


# 不要になったビルドイメージを削除
_postBuild:
	@if [[ -n $$(docker images -f 'dangling=true' -q) ]]; then\
		docker image rm $$(docker images -f 'dangling=true' -q);\
	fi
	docker system df



# semi-latex環境の構築
install:
	@if [[ -n $$(docker --version 2>/dev/null) ]] || [[ $$(uname) == "Linux" ]]; then\
		make install-docker -s;\
	fi


# UbuntuにDockerをインストールし，sudoなしでDockerコマンドを実行するよう設定
install-docker:
	@if [[ -n $$(docker --version 2>/dev/null) ]]; then\
		echo "Docker is already installed";\
		docker --version;\
		exit 1;\
	fi
	sudo apt update
	sudo apt install -y docker.io docker-buildx
	[[ $$(getent group docker | cut -f 4 --delim=":") != $$(whoami) ]] && sudo gpasswd -a $$(whoami) docker
	sudo chgrp docker /var/run/docker.sock
	sudo systemctl restart docker
	@echo "環境構築を完了するために再起動してください"

install-textlint:
	sudo apt install nodejs npm
	sudo npm install n -g
	sudo n lts
	npm install

push-image:
	docker tag ${NAME}:${ARCH} ${DOCKER_REPOSITORY}:${ARCH}
	docker push ${DOCKER_REPOSITORY}:${ARCH}
	docker image rm ${DOCKER_REPOSITORY}:${ARCH}

get-image:
	docker pull ${DOCKER_REPOSITORY}:${ARCH}
	docker tag ${DOCKER_REPOSITORY}:${ARCH} ${NAME}:${ARCH}
	docker image rm ${DOCKER_REPOSITORY}:${ARCH}
	docker pull ${PYTHON_REPOSITORY}


# サンプルのビルドテスト
test:
	bash internal/test/test.sh ${ARCH}

sandbox:
	echo ${TEX_FILE_PATH}
