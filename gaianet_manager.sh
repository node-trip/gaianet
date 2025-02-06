#!/bin/bash

# Цветовые коды
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Функция очистки экрана
clear_screen() {
    clear
    echo -e "${BLUE}=== GaiaNet Node Manager ===${NC}"
    echo -e "${GREEN}Telegram: @nodetrip${NC}\n"
}

# Функция инициализации окружения
init_environment() {
    # Загрузка переменных окружения
    if [ -f "/root/.wasmedge/env" ]; then
        source /root/.wasmedge/env
    fi
    if [ -f "/root/.bashrc" ]; then
        source /root/.bashrc
    fi
    
    # Добавление путей в PATH если их там нет
    if [[ ":$PATH:" != *":/root/.wasmedge/bin:"* ]]; then
        export PATH="/root/.wasmedge/bin:$PATH"
    fi
}

# Функция для установки новой ноды
install_node() {
    clear_screen
    echo -e "${YELLOW}Установка новой ноды GaiaNet${NC}"
    read -p "Введите номер ноды: " node_number
    
    if [ "$node_number" -eq 1 ]; then
        NODE_DIR="/root/gaianet"
        NODE_NAME="gaianet"
    else
        NODE_DIR="/root/gaianet-$node_number"
        NODE_NAME="gaianet-$node_number"
    fi

    # Удаляем старую директорию если существует
    if [ -d "$NODE_DIR" ]; then
        echo -e "${YELLOW}Удаление старой директории...${NC}"
        rm -rf "$NODE_DIR"
    fi

    # Создаем новую директорию
    echo -e "${YELLOW}Создание директории для установки...${NC}"
    mkdir -p "$NODE_DIR"
    cd "$NODE_DIR" || exit 1
    
    # Обновление системы и установка ноды
    echo -e "\n${YELLOW}Обновление системы...${NC}"
    sudo apt update -y && sudo apt-get update -y >/dev/null 2>&1
    
    echo -e "${YELLOW}Установка GaiaNet...${NC}"
    # Сохраняем текущую директорию
    CURRENT_DIR=$(pwd)
    cd "$NODE_DIR" || exit 1
    
    # Выполняем установку
    curl -sSfL 'https://github.com/GaiaNet-AI/gaianet-node/releases/latest/download/install.sh' -o install.sh
    chmod +x install.sh
    INSTALL_OUTPUT=$(./install.sh --base "$NODE_DIR")
    echo "$INSTALL_OUTPUT"
    
    # Возвращаемся в исходную директорию
    cd "$CURRENT_DIR" || exit 1
    
    # Проверяем успешность установки
    if [ ! -f "$NODE_DIR/bin/gaianet" ]; then
        echo -e "${RED}Ошибка: Установка не удалась${NC}"
        read -p "Нажмите Enter для возврата в меню"
        return 1
    fi

    # Автоматическая инициализация окружения
    echo -e "\n${YELLOW}Настройка окружения...${NC}"
    init_environment

    # Настройка порта и конфигурации
    echo -e "${YELLOW}Настройка конфигурации...${NC}"
    LLAMAEDGE_PORT=$((8080 + (node_number - 1) * 5))
    
    # Инициализация с новым портом
    cd "$NODE_DIR" && "$NODE_DIR/bin/gaianet" init --config "https://raw.gaianet.ai/qwen2-0.5b-instruct/config.json" --base "$NODE_DIR"
    
    # Проверяем наличие config.json
    if [ -f "$NODE_DIR/config.json" ]; then
        # Обновляем порт в конфигурации
        sed -i "s/\"llamaedge_port\": \"[0-9]*\"/\"llamaedge_port\": \"$LLAMAEDGE_PORT\"/" "$NODE_DIR/config.json"
    else
        echo -e "${RED}Ошибка: Файл конфигурации не найден${NC}"
    fi

    # Создание службы systemd
    echo -e "${YELLOW}Настройка системного сервиса...${NC}"
    create_service $node_number "$NODE_DIR" "$NODE_NAME"

    # Установка дополнительных компонентов
    echo -e "${YELLOW}Настройка дополнительных компонентов...${NC}"
    setup_chat_script $node_number "$NODE_DIR"

    echo -e "\n${GREEN}Установка успешно завершена!${NC}"
    echo -e "${GREEN}Нода $node_number готова к работе${NC}"
    read -p "Нажмите Enter для возврата в меню"
}

# Функция создания systemd службы
create_service() {
    local node_number=$1
    local node_dir=$2
    local node_name=$3
    
    cat <<EOL | sudo tee /etc/systemd/system/$node_name.service
[Unit]
Description=Gaianet Node Service $node_number
After=network.target

[Service]
Type=forking
RemainAfterExit=true
Environment=PATH=/root/.wasmedge/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$node_dir/bin/gaianet start --base $node_dir
ExecStop=$node_dir/bin/gaianet stop --base $node_dir
ExecStopPost=/bin/sleep 20
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl restart $node_name.service
    sudo systemctl enable $node_name.service
}

# Функция настройки скрипта чата
setup_chat_script() {
    local node_number=$1
    local node_dir=$2
    
    echo "Установка зависимостей..."
    sudo apt install -y python3-pip nano screen >/dev/null 2>&1
    pip install requests faker >/dev/null 2>&1

    # Получаем информацию о ноде
    cd "$node_dir" && "$node_dir/bin/gaianet" info > "$node_dir/gaianet_info.txt"
    NODE_ID=$(grep 'Node ID:' "$node_dir/gaianet_info.txt" | awk '{print $3}')
    
    if [ -z "$NODE_ID" ]; then
        echo -e "${RED}Ошибка: Не удалось получить Node ID${NC}"
        return 1
    fi
    
    echo "Создание скрипта чата..."
    create_chat_script $node_number $NODE_ID
    
    if [ ! -f "/root/random_chat_with_faker_$node_number.py" ]; then
        echo -e "${RED}Ошибка: Скрипт чата не создан${NC}"
        return 1
    fi
    
    # Ждем запуска ноды
    echo "Ожидание запуска ноды..."
    sleep 10
    
    # Останавливаем существующую сессию если есть
    screen -wipe >/dev/null 2>&1
    if screen -list | grep -q "faker_session_$node_number"; then
        screen -S "faker_session_$node_number" -X quit >/dev/null 2>&1
        sleep 2
    fi
    
    echo "Запуск новой screen сессии..."
    # Запускаем screen с логированием ошибок
    cd /root
    screen -dmS "faker_session_$node_number" bash -c "python3 random_chat_with_faker_$node_number.py"
    
    # Ждем немного и проверяем
    sleep 3
    
    # Проверяем что сессия запустилась
    if screen -list | grep -q "faker_session_$node_number"; then
        echo -e "${GREEN}Screen сессия успешно запущена${NC}"
        # Проверяем создание лог файла
        for i in {1..5}; do
            if [ -f "chat_log_$node_number.txt" ]; then
                echo -e "${GREEN}Лог файл создан${NC}"
                break
            fi
            echo "Ожидание создания лог файла... попытка $i"
            sleep 2
        done
    else
        echo -e "${RED}Ошибка запуска screen сессии${NC}"
        if [ -f "/root/screen_log_$node_number.txt" ]; then
            echo "Лог ошибки screen:"
            cat "/root/screen_log_$node_number.txt"
        fi
        echo "Текущие screen сессии:"
        screen -ls
    fi
}

# Функция для просмотра информации о нодах
view_nodes_info() {
    clear_screen
    echo -e "${YELLOW}Информация о нодах:${NC}\n"
    
    for dir in /root/gaianet*; do
        if [ -d "$dir" ]; then
            node_num=$(echo $dir | grep -o '[0-9]*$')
            [ -z "$node_num" ] && node_num=1
            
            echo -e "${GREEN}=== Нода $node_num ===${NC}"
            
            # Получаем информацию о ноде с указанием базовой директории
            cd $dir && $dir/bin/gaianet info --base $dir > "$dir/gaianet_info.txt"
            
            # Читаем Node ID из gaianet_info.txt
            if [ -f "$dir/gaianet_info.txt" ]; then
                NODE_ID=$(grep "Node ID:" "$dir/gaianet_info.txt" | cut -d' ' -f3)
                echo -e "Node ID: ${YELLOW}$NODE_ID${NC}"
            fi
            
            # Читаем Device ID из frpc.toml с новым форматом
            if [ -f "$dir/gaia-frp/frpc.toml" ]; then
                DEVICE_ID=$(grep "metadatas.deviceId" "$dir/gaia-frp/frpc.toml" | cut -d'"' -f2)
                if [ ! -z "$DEVICE_ID" ]; then
                    echo -e "Device ID: ${YELLOW}$DEVICE_ID${NC}"
                fi
            fi
            
            echo ""
        fi
    done
    
    read -p "Нажмите Enter для возврата в меню"
}

# Функция для управления screen сессиями
manage_screens() {
    clear_screen
    echo -e "${YELLOW}Управление screen сессиями:${NC}\n"
    echo "Активные сессии:"
    screen -ls
    echo -e "\n1. Подключиться к сессии"
    echo "2. Вернуться в меню"
    
    read -p "Выберите действие: " choice
    case $choice in
        1)
            read -p "Введите номер ноды для подключения к её сессии: " node_num
            screen -r "faker_session_$node_num"
            ;;
        2)
            return
            ;;
    esac
}

# Функция проверки статуса ноды
check_node_status() {
    local node_number=$1
    local node_name
    local node_dir
    
    if [ "$node_number" -eq 1 ]; then
        node_name="gaianet"
        node_dir="/root/gaianet"
    else
        node_name="gaianet-$node_number"
        node_dir="/root/gaianet-$node_number"
    fi

    echo -e "\n${YELLOW}Проверка статуса ноды $node_number:${NC}"
    
    # Проверка существования директории
    if [ ! -d "$node_dir" ]; then
        echo -e "${RED}✗ Директория ноды не найдена${NC}"
        return 1
    else
        echo -e "${GREEN}✓ Директория ноды существует${NC}"
    fi
    
    # Проверка systemd сервиса
    if systemctl is-active --quiet $node_name; then
        echo -e "${GREEN}✓ Сервис ноды активен${NC}"
        systemctl status $node_name | grep "Active:"
    else
        echo -e "${RED}✗ Сервис ноды не активен${NC}"
    fi
    
    # Проверка screen сессии
    if screen -list | grep -q "faker_session_$node_number"; then
        echo -e "${GREEN}✓ Screen сессия активна${NC}"
    else
        echo -e "${RED}✗ Screen сессия не активна${NC}"
    fi
    
    # Проверка файлов чата
    if [ -f "/root/random_chat_with_faker_$node_number.py" ]; then
        echo -e "${GREEN}✓ Скрипт чата существует${NC}"
    else
        echo -e "${RED}✗ Скрипт чата не найден${NC}"
    fi
    
    if [ -f "/root/chat_log_$node_number.txt" ]; then
        echo -e "${GREEN}✓ Лог чата существует${NC}"
        echo -e "${YELLOW}Последние сообщения из лога:${NC}"
        tail -n 5 "/root/chat_log_$node_number.txt"
    else
        echo -e "${RED}✗ Лог чата не найден${NC}"
    fi
}

# Функция для удаления ноды
remove_node() {
    clear_screen
    echo -e "${RED}Удаление ноды${NC}"
    read -p "Введите номер ноды для удаления: " node_number
    
    if [ "$node_number" -eq 1 ]; then
        NODE_DIR="/root/gaianet"
        NODE_NAME="gaianet"
    else
        NODE_DIR="/root/gaianet-$node_number"
        NODE_NAME="gaianet-$node_number"
    fi

    # Проверяем статус перед удалением
    check_node_status $node_number
    
    echo -e "\n${RED}Вы уверены, что хотите удалить ноду $node_number? (y/n)${NC}"
    read -p "Ваш выбор: " confirm
    
    if [ "$confirm" != "y" ]; then
        echo -e "${YELLOW}Удаление отменено${NC}"
        read -p "Нажмите Enter для возврата в меню"
        return
    fi

    echo -e "\n${YELLOW}Начинаю удаление ноды...${NC}"

    # Остановка и удаление службы
    if systemctl is-active --quiet $NODE_NAME; then
        echo "Останавливаю сервис..."
        sudo systemctl stop $NODE_NAME.service
    fi
    
    if systemctl is-enabled --quiet $NODE_NAME; then
        echo "Отключаю автозапуск сервиса..."
        sudo systemctl disable $NODE_NAME.service
    fi
    
    echo "Удаляю файл сервиса..."
    sudo rm -f /etc/systemd/system/$NODE_NAME.service
    sudo systemctl daemon-reload

    # Удаление screen сессии
    if screen -list | grep -q "faker_session_$node_number"; then
        echo "Закрываю screen сессию..."
        screen -S "faker_session_$node_number" -X quit
    fi

    # Удаление файлов
    echo "Удаляю файлы ноды..."
    rm -rf $NODE_DIR
    rm -f /root/random_chat_with_faker_$node_number.py
    rm -f chat_log_$node_number.txt

    # Проверяем статус после удаления
    echo -e "\n${YELLOW}Проверка после удаления:${NC}"
    check_node_status $node_number

    echo -e "\n${GREEN}Нода $node_number успешно удалена${NC}"
    read -p "Нажмите Enter для возврата в меню"
}

# Создание скрипта чата
create_chat_script() {
    local node_number=$1
    local node_id=$2
    
    # Очищаем node_id от всех специальных символов и берем только первые 42 символа
    node_id=$(echo "$node_id" | sed 's/[^a-zA-Z0-9]//g' | cut -c1-42)
    
    cat <<'EOL' > "/root/random_chat_with_faker_$node_number.py"
import requests
import random
import logging
import time
from faker import Faker
from datetime import datetime

# Конфигурация
NODE_URL = "https://__NODE_ID__.gaia.domains/v1/chat/completions"

faker = Faker()

headers = {
    "accept": "application/json",
    "Content-Type": "application/json"
}

# Настройка логирования
logging.basicConfig(
    filename='chat_log___NODE_NUMBER__.txt',
    level=logging.INFO,
    format='%(asctime)s - %(message)s'
)

def log_message(node, message):
    logging.info(f"{node}: {message}")

def send_message(node_url, message):
    try:
        response = requests.post(node_url, json=message, headers=headers)
        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"Failed to get response from API: {e}")
        return None

def extract_reply(response):
    if response and 'choices' in response:
        return response['choices'][0]['message']['content']
    return ""

# Ждем запуска сервиса
print("Waiting for service to start...")
time.sleep(10)

while True:
    try:
        random_question = faker.sentence(nb_words=10)
        message = {
            "messages": [
                {"role": "system", "content": "You are a helpful assistant."},
                {"role": "user", "content": random_question}
            ]
        }

        question_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        response = send_message(NODE_URL, message)
        reply = extract_reply(response)
        reply_time = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

        log_message("Node replied", f"Q ({question_time}): {random_question} A ({reply_time}): {reply}")
        print(f"Q ({question_time}): {random_question}\nA ({reply_time}): {reply}")

        delay = random.randint(1, 3)
        time.sleep(delay)
    except Exception as e:
        print(f"Error occurred: {str(e)}")
        time.sleep(5)
EOL

    # Заменяем плейсхолдеры на реальные значения
    sed -i "s/__NODE_ID__/$node_id/" "/root/random_chat_with_faker_$node_number.py"
    sed -i "s/__NODE_NUMBER__/$node_number/g" "/root/random_chat_with_faker_$node_number.py"
}

# Функция для перезапуска ноды
restart_node() {
    local node_number=$1
    local node_name
    
    if [ "$node_number" -eq 1 ]; then
        node_name="gaianet"
    else
        node_name="gaianet-$node_number"
    fi

    echo -e "${YELLOW}Перезапуск ноды $node_number...${NC}"
    systemctl restart $node_name && sleep 30 && screen -S faker_session_$node_number -X quit && sleep 2 && cd /root && screen -dmS faker_session_$node_number python3 random_chat_with_faker_$node_number.py
    
    # Записываем время последнего перезапуска
    echo "$(date '+%Y-%m-%d %H:%M:%S')" > "/root/.last_restart_node_$node_number"
    
    echo -e "${GREEN}Перезапуск завершен!${NC}"
}

# Функция для настройки расписания перезапуска
setup_restart_schedule() {
    local node_number=$1
    local hours=$2
    
    # Удаляем старое расписание если есть
    crontab -l | grep -v "restart_node_$node_number" | crontab -
    
    # Добавляем новое расписание
    (crontab -l 2>/dev/null; echo "0 */$hours * * * /root/gaianet_manager.sh --restart-node $node_number") | crontab -
    
    # Сохраняем информацию о расписании
    echo "$hours" > "/root/.restart_schedule_node_$node_number"
    
    echo -e "${GREEN}Расписание перезапуска настроено на каждые $hours часов${NC}"
}

# Функция для просмотра информации о расписании
view_restart_info() {
    local node_number=$1
    
    echo -e "${YELLOW}Информация о перезапусках ноды $node_number:${NC}"
    
    # Проверяем настроенное расписание
    if [ -f "/root/.restart_schedule_node_$node_number" ]; then
        hours=$(cat "/root/.restart_schedule_node_$node_number")
        echo -e "Расписание: ${GREEN}каждые $hours часов${NC}"
    else
        echo -e "Расписание: ${RED}не настроено${NC}"
    fi
    
    # Проверяем время последнего перезапуска
    if [ -f "/root/.last_restart_node_$node_number" ]; then
        last_restart=$(cat "/root/.last_restart_node_$node_number")
        echo -e "Последний перезапуск: ${GREEN}$last_restart${NC}"
    else
        echo -e "Последний перезапуск: ${RED}нет информации${NC}"
    fi
}

# Функция для смены домена в чат-боте
change_chat_domain() {
    local node_number=$1
    
    echo -e "${YELLOW}Смена домена для чат-бота ноды $node_number${NC}"
    echo "Текущий домен:"
    grep "NODE_URL" "/root/random_chat_with_faker_$node_number.py"
    
    read -p "Введите новый домен (например, vkvik.gaia.domains): " new_domain
    
    # Создаем бэкап скрипта
    cp "/root/random_chat_with_faker_$node_number.py" "/root/random_chat_with_faker_$node_number.py.backup"
    
    # Обновляем URL в скрипте
    sed -i "s|NODE_URL = \"https://.*\.gaia\.domains/v1/chat/completions\"|NODE_URL = \"https://$new_domain/v1/chat/completions\"|" "/root/random_chat_with_faker_$node_number.py"
    
    echo -e "${GREEN}Домен обновлен. Новый URL:${NC}"
    grep "NODE_URL" "/root/random_chat_with_faker_$node_number.py"
    
    echo -e "\n${YELLOW}Перезапуск чат-бота...${NC}"
    screen -S "faker_session_$node_number" -X quit && sleep 2 && cd /root && screen -dmS "faker_session_$node_number" python3 "random_chat_with_faker_$node_number.py"
    
    echo -e "${GREEN}Чат-бот перезапущен!${NC}"
}

# Функция управления перезапуском
manage_restart() {
    while true; do
        clear_screen
        echo -e "${YELLOW}Управление перезапуском:${NC}\n"
        echo "1. Перезапустить ноду сейчас"
        echo "2. Настроить расписание перезапуска"
        echo "3. Просмотреть информацию о перезапусках"
        echo "4. Сменить домен чат-бота"
        echo "5. Вернуться в главное меню"
        
        read -p "Выберите действие: " choice
        
        case $choice in
            1)
                read -p "Введите номер ноды для перезапуска: " node_number
                restart_node $node_number
                read -p "Нажмите Enter для продолжения"
                ;;
            2)
                read -p "Введите номер ноды: " node_number
                read -p "Через сколько часов перезапускать ноду? " hours
                setup_restart_schedule $node_number $hours
                read -p "Нажмите Enter для продолжения"
                ;;
            3)
                read -p "Введите номер ноды: " node_number
                view_restart_info $node_number
                read -p "Нажмите Enter для продолжения"
                ;;
            4)
                read -p "Введите номер ноды: " node_number
                change_chat_domain $node_number
                read -p "Нажмите Enter для продолжения"
                ;;
            5)
                return
                ;;
            *)
                echo "Неверный выбор"
                ;;
        esac
    done
}

# Проверяем аргументы командной строки для автоматического перезапуска
if [ "$1" = "--restart-node" ] && [ ! -z "$2" ]; then
    restart_node $2
    exit 0
fi

# Главное меню
while true; do
    clear_screen
    echo "1. Установить новую ноду"
    echo "2. Просмотреть информацию о нодах"
    echo "3. Управление screen сессиями"
    echo "4. Удалить ноду"
    echo "5. Проверить статус ноды"
    echo "6. Управление перезапуском"
    echo "7. Выход"
    
    read -p "Выберите действие: " choice
    
    case $choice in
        1) install_node ;;
        2) view_nodes_info ;;
        3) manage_screens ;;
        4) remove_node ;;
        5) 
            read -p "Введите номер ноды для проверки: " node_number
            check_node_status $node_number
            read -p "Нажмите Enter для возврата в меню"
            ;;
        6) manage_restart ;;
        7) exit 0 ;;
        *) echo "Неверный выбор" ;;
    esac
done 
