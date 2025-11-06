#!/data/data/com.termux/files/usr/bin/sh

# === 1. 패키지 설치 ===
echo "--- 패키지 설치를 시작합니다 ---"
pkg update -y
pkg install -y python cronie python-pip
command -v pip >/dev/null 2>&1 || pkg install -y python-pip
export PATH=$PREFIX/bin:$PATH
pip install --quiet --no-input requests pytz holidays

# === 2. 사용자 정보 입력받기 ===
echo "--- 텔레그램 정보를 입력하세요 ---"
printf "텔레그램 봇 KEY를 입력한 후 엔터를 누르세요: "
read -r BOT_KEY

printf "텔레그램 ID를 입력한 후 엔터를 누르세요: "
read -r CHAT_ID

echo "--- 사용할 종목 코드를 입력하세요 ---"

printf "[1/3] 전략 기준이 될 메인 티커 (예: TQQQ, QLD): "
read -r TICKER_MAIN
TICKER_MAIN=$(echo "$TICKER_MAIN" | tr '[:lower:]' '[:upper:]' | xargs)

printf "[2/3] 안전 자산 코드 (예: SGOV, USFR): "
read -r TICKER_RISK_OFF
TICKER_RISK_OFF=$(echo "$TICKER_RISK_OFF" | tr '[:lower:]' '[:upper:]' | xargs)

printf "[3/3] 추가 매수 자산 코드 (예: SPYM, VOO): "
read -r TICKER_RISK_ON
TICKER_RISK_ON=$(echo "$TICKER_RISK_ON" | tr '[:lower:]' '[:upper:]' | xargs)

# === 3. 파이썬 파일 자동 생성 ===
echo "--- $TICKER_MAIN.py 파일을 생성합니다 ---"
cat << EOF > "$HOME/$TICKER_MAIN.py"
#!/data/data/com.termux/files/usr/bin/python
# -*- coding: utf-8 -*-

import os
import time
import json
import pytz
import requests
import holidays
from datetime import datetime, timedelta, date

# =========================
# 환경설정 / 상수
# =========================
TELEGRAM_TOKEN = "$BOT_KEY"
CHAT_ID = "$CHAT_ID"

TICKER_MAIN = "$TICKER_MAIN"
TICKER_RISK_OFF = "$TICKER_RISK_OFF"
TICKER_RISK_ON = "$TICKER_RISK_ON"

MAX_RETRIES = 180
SLEEP_BASE = 10
SLEEP_CAP = 60
SLEEP_FIXED = 17

# [!] (수정) 여러 전략이 충돌하지 않도록 파일명을 고유하게 변경
PREV_FILE = "/data/data/com.termux/files/home/prev_conditions_$TICKER_MAIN.txt"
os.makedirs(os.path.dirname(PREV_FILE), exist_ok=True)

EST = pytz.timezone('US/Eastern')

# =========================
# 공통 유틸
# =========================
session = requests.Session()
session.headers.update({'User-Agent': 'Mozilla/5.0'})

def tz_label(dt_est: datetime) -> str:
    return "EDT" if dt_est.dst() != timedelta(0) else "EST"

def send_telegram(html_text: str) -> None:
    try:
        resp = session.post(
            f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage",
            data={"chat_id": CHAT_ID, "text": html_text, "parse_mode": "HTML"},
            timeout=8
        )
        if not resp.ok:
            print(f"텔레그램 응답 오류: {resp.status_code} {resp.text[:200]}")
        else:
            print("텔레그램 전송 성공!")
    except Exception as e:
        print(f"텔레그램 전송 실패: {e}")

def get_prev_conditions():
    try:
        with open(PREV_FILE, 'r') as f:
            parts = f.read().strip().split(',')
            if len(parts) == 3:
                return int(parts[1]), int(parts[0])
    except (FileNotFoundError, IOError, ValueError):
        pass
    return 0, 0

def save_prev_conditions(today_cond, yesterday_cond, day_before_cond):
    try:
        with open(PREV_FILE, 'w') as f:
            f.write(f"{day_before_cond},{yesterday_cond},{today_cond}")
    except (IOError, OSError) as e:
        print(f"경고: 이전 상태 파일 저장 실패 - {e}")

def cond_to_msg(cond):
    if cond == 1: return f"전량 {TICKER_RISK_OFF}"
    if cond == 2: return f"{TICKER_RISK_OFF} → {TICKER_MAIN}"
    if cond == 3: return f"{TICKER_MAIN} 유지 + {TICKER_RISK_ON} 매수"
    return "알 수 없음"

# =========================
# 조기폐장 간단 규칙
# =========================
def get_nyse_close_hour(est_date: date) -> int:
    y = est_date.year
    wk = est_date.weekday()
    # 11월 1일 기준, 넷째 주 목요일(추수감사절) 찾기
    tg = date(y, 11, 1) + timedelta(days=(3 - date(y,11,1).weekday()) % 7 + 21)
    if est_date == tg + timedelta(days=1): # 추수감사절 다음 날
        return 13
    if est_date.month == 12 and est_date.day == 24 and wk < 5: # 크리스마스 이브
        return 13
    if est_date.month == 7 and est_date.day == 3 and 1 <= date(y,7,4).weekday() <= 4: # 독립기념일 전날
        return 13
    return 16

# =========================
# 메인: 날짜/휴일/대기
# =========================
now = datetime.now(EST)
today_date = now.date()
weekday = now.weekday()

try:
    us_holidays = holidays.NYSE(years={now.year, now.year + 1})
except Exception:
    us_holidays = holidays.US(years={now.year, now.year + 1})

if weekday >= 5:
    print(f"[{now:%Y-%m-%d}] 미국 시장 휴장(주말) → 종료")
    raise SystemExit(0)
if today_date in us_holidays:
    print(f"[{now:%Y-%m-%d}] 미국 시장 휴장({us_holidays.get(today_date)}) → 종료")
    raise SystemExit(0)

close_hour = get_nyse_close_hour(today_date)
print(f"오늘 마감 시간: {close_hour}:00 {tz_label(now)}")
target = now.replace(hour=close_hour, minute=4, second=0, microsecond=0)

if now < target:
    wait_seconds = int((target - now).total_seconds())
    print(f"{close_hour}:04 {tz_label(now)}(장 마감)까지 {wait_seconds}초 대기...")
    time.sleep(wait_seconds)

print(f"장 마감. 16:04부터 {TICKER_MAIN} 데이터 폴링 시작...")

# =========================
# Yahoo 데이터 → 200MA
# =========================
final_time_str = ""
close = ma = ma5 = None
data_found = False

for retries in range(MAX_RETRIES):
    try:
        resp = session.get(
            f"https://query1.finance.yahoo.com/v8/finance/chart/{TICKER_MAIN}",
            params={
                "period1": int((datetime.now(EST) - timedelta(days=400)).timestamp()),
                "period2": int(datetime.now(EST).timestamp()),
                "interval": "1d",
                "includeAdjustedClose": "true"
            },
            timeout=10
        ).json()

        result = resp.get("chart", {}).get("result", [])
        if not result:
            raise ValueError("chart.result 없음")

        ts = result[0]["timestamp"]
        closes = result[0]["indicators"]["quote"][0]["close"]
        latest = datetime.fromtimestamp(ts[-1], tz=EST).date()

        if latest != today_date:
            print(f"...아직 어제({latest}). {SLEEP_FIXED}초 후 재시도")
            time.sleep(SLEEP_FIXED)
            continue
        if closes[-1] is None:
            print(f"...종가 None. {SLEEP_FIXED}초 후 재시도")
            time.sleep(SLEEP_FIXED)
            continue

        final_time_str = datetime.now(EST).strftime("%H:%M:%S")
        print(f"[{final_time_str}] 데이터 업데이트 완료")

        close = float(closes[-1])
        last200 = [c for c in closes[-200:] if c is not None]
        ma = sum(last200) / len(last200)
        ma5 = ma * 1.05
        data_found = True
        break

    except Exception as e:
        s = min(SLEEP_BASE * (1.2 ** retries), SLEEP_CAP)
        print(f"오류: {e} → {int(s)}초 후 재시도")
        time.sleep(s)

# =========================
# 전략 판단 / 저장
# =========================
yesterday_cond, day_before_cond = get_prev_conditions()
today_cond = 0
msg = ""

if not data_found or close is None:
    msg = "<b>[오류]</b>\n데이터 수집 실패"
    today_cond = yesterday_cond
else:
    if close < ma:
        today_cond = 1
        msg = f"전량 {TICKER_RISK_OFF}" if yesterday_cond != 1 else f"{TICKER_RISK_OFF} 유지"
    elif ma <= close < ma5:
        today_cond = 2
        # [!] "어제가 1(TICKER_RISK_OFF)이었으면 '대기', 아니었으면 '매수'" 로직 추가
        if yesterday_cond == 1:
            msg = f"{TICKER_RISK_OFF} 대기"
        else:
            msg = f"{TICKER_RISK_OFF} → {TICKER_MAIN}"
    else:
        today_cond = 3
        msg = f"{TICKER_MAIN} 유지 + {TICKER_RISK_ON} 매수"

    save_prev_conditions(today_cond, yesterday_cond, day_before_cond)

# =========================
# 텔레그램 전송
# =========================
label = tz_label(datetime.now(EST))
if not data_found or close is None:
    details = (
        f"<b>{TICKER_MAIN} 200MA 전략 (실패)</b>\n\n"
        f"<b>{msg}</b>\n"
        f"D-1: {cond_to_msg(yesterday_cond)}\n"
        f"D-2: {cond_to_msg(day_before_cond)}\n"
    )
else:
    # [!] (수정) "Bad substitution" 오류를 막기 위해 $ 앞에 \ (백슬래시) 추가
    details = (
        f"<b>{TICKER_MAIN} 200MA 전략 ({final_time_str} {label})</b>\n\n"
        f"<b>{msg}</b>\n\n"
        f"<b>--- 데이터 ---</b>\n"
        f"{TICKER_MAIN} 종가: \${close:.2f}\n"
        f"200MA: \${ma:.2f}\n"
        f"MA+5%: \${ma5:.2f}\n"
        f"D-1: {cond_to_msg(yesterday_cond)}\n"
        f"D-2: {cond_to_msg(day_before_cond)}\n"
    )

send_telegram(details)
EOF

# 파이썬 파일에 실행 권한 부여
chmod +x "$HOME/$TICKER_MAIN.py"

# === 4. 자동 실행 설정 ===
echo "--- 자동 실행 설정을 진행합니다 ---"

# 크론탭 (매일 16:04 EST)
# 기존 crontab 내용에 덮어쓰지 않고 추가
(crontab -l 2>/dev/null; echo ""; echo "CRON_TZ=US/Eastern"; echo "4 16 * * * $HOME/$TICKER_MAIN.py >> $HOME/$TICKER_MAIN.log 2>&1") | crontab -

# 부팅 시 crond 자동 시작
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/start_crond" <<'EOS'
#!/data/data/com.termux/files/usr/bin/sh
crond
EOS
chmod +x "$HOME/.termux/boot/start_crond"

# 즉시 crond 실행
crond

echo "--- [$TICKER_MAIN] 전략 설정이 완료되었습니다! ---"