#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
AUTH_FILE="${1:-$PROJECT_DIR/.auth}"
"$PROJECT_DIR/scripts/prepare-dependencies.sh"
DEPENDENCY_ROOT="${NULCONNECT_DEPENDENCY_ROOT:-$PROJECT_DIR/.build/dependencies/$(uname -m)}"
HEADER_DIR="$DEPENDENCY_ROOT/libreatrust/include"
LIB_DIR="$DEPENDENCY_ROOT/libreatrust/dynamic"
LIBRARY="$LIB_DIR/libreatrust.dylib"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nulconnect-password-auth.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

if [[ ! -f "$AUTH_FILE" ]]; then
    echo "error: credentials file not found: $AUTH_FILE" >&2
    echo "expected line 1 to contain the username and line 2 to contain the password" >&2
    exit 2
fi

if [[ ! -f "$LIBRARY" ]]; then
    echo "error: libreatrust dynamic library not found: $LIBRARY" >&2
    exit 2
fi

if [[ "$(uname -m)" != "arm64" && "$(uname -m)" != "x86_64" ]]; then
    echo "error: unsupported macOS architecture: $(uname -m)" >&2
    exit 2
fi

permissions="$(stat -f '%Lp' "$AUTH_FILE")"
if (( (8#$permissions & 8#077) != 0 )); then
    echo "error: $AUTH_FILE is readable or writable by other users (mode $permissions)" >&2
    echo "run: chmod 600 '$AUTH_FILE'" >&2
    exit 2
fi

cat > "$WORK_DIR/password_auth.c" <<'C_SOURCE'
#include "libreatrust.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *kUserAgent =
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "aTrustTray/2.4.10.50 Chrome/83.0.4103.94 Electron/9.0.2 Safari/537.36 "
    "aTrustTray-Linux-Plat-Ubuntu-x64 SPCClientType";

static void secure_clear(char *value) {
    if (value == NULL) {
        return;
    }
    volatile char *cursor = value;
    size_t length = strlen(value);
    while (length-- > 0) {
        *cursor++ = 0;
    }
}

static void trim_line_ending(char *value) {
    size_t length = strlen(value);
    while (length > 0 && (value[length - 1] == '\n' || value[length - 1] == '\r')) {
        value[--length] = '\0';
    }
}

static int read_credentials(const char *path, char **username, char **password) {
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        fprintf(stderr, "error: cannot open credentials: %s\n", strerror(errno));
        return -1;
    }

    size_t username_capacity = 0;
    size_t password_capacity = 0;
    ssize_t username_length = getline(username, &username_capacity, file);
    ssize_t password_length = getline(password, &password_capacity, file);
    fclose(file);

    if (username_length <= 0 || password_length <= 0) {
        fprintf(stderr, "error: credentials file must contain a username and password\n");
        return -1;
    }
    trim_line_ending(*username);
    trim_line_ending(*password);
    if ((*username)[0] == '\0' || (*password)[0] == '\0') {
        fprintf(stderr, "error: username and password must not be empty\n");
        return -1;
    }
    return 0;
}

static void make_device_id(char output[33]) {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    for (size_t index = 0; index < sizeof(bytes); ++index) {
        snprintf(output + index * 2, 3, "%02x", bytes[index]);
    }
    output[32] = '\0';
}

static int report_error(const char *operation, int code) {
    const char *message = atr_last_error_message();
    fprintf(stderr, "[password-auth] %s failed (code=%d): %s\n",
            operation, code, message == NULL ? "unknown error" : message);
    return code;
}

static int write_captcha(const atr_blob_t *image, char path[80]) {
    snprintf(path, 80, "/tmp/nulconnect-auth-captcha.XXXXXX.jpg");
    int descriptor = mkstemps(path, 4);
    if (descriptor < 0) {
        fprintf(stderr, "error: cannot create captcha file: %s\n", strerror(errno));
        return -1;
    }
    ssize_t written = write(descriptor, image->data, image->len);
    close(descriptor);
    if (written < 0 || (size_t)written != image->len) {
        fprintf(stderr, "error: cannot write captcha image\n");
        unlink(path);
        return -1;
    }
    return 0;
}

static int write_captcha_page(const char *image_path, char page_path[96]) {
    snprintf(page_path, 96, "%s.html", image_path);
    FILE *page = fopen(page_path, "w");
    if (page == NULL) {
        fprintf(stderr, "error: cannot create captcha page: %s\n", strerror(errno));
        return -1;
    }
    fprintf(page,
        "<!doctype html><meta charset='utf-8'><title>NulConnect password test</title>"
        "<style>body{font:15px -apple-system;margin:32px;color:#202124}"
        ".wrap{position:relative;display:inline-block}img{display:block}"
        ".dot{position:absolute;width:18px;height:18px;margin:-9px;border-radius:50%%;"
        "background:#087ff5;color:white;text-align:center;line-height:18px;font-size:11px;pointer-events:none}"
        "textarea{display:block;width:520px;height:64px;margin:16px 0;font:12px monospace}</style>"
        "<h2>按图片要求依次点击字符</h2><p>点击完成后复制生成的 JSON，粘贴回终端。</p>"
        "<div class='wrap' id='wrap'><img id='captcha' src='file://%s'></div>"
        "<textarea id='result' readonly></textarea>"
        "<button onclick='copyResult()'>复制 JSON</button> <button onclick='resetPoints()'>重新选择</button>"
        "<script>const img=document.getElementById('captcha'),wrap=document.getElementById('wrap'),"
        "result=document.getElementById('result');let points=[];"
        "img.onclick=e=>{const r=img.getBoundingClientRect();"
        "const x=Math.round((e.clientX-r.left)*img.naturalWidth/r.width),"
        "y=Math.round((e.clientY-r.top)*img.naturalHeight/r.height);points.push([x,y]);"
        "const d=document.createElement('span');d.className='dot';d.style.left=(e.clientX-r.left)+'px';"
        "d.style.top=(e.clientY-r.top)+'px';d.textContent=points.length;wrap.appendChild(d);update()};"
        "function update(){result.value=JSON.stringify({coordinates:points,width:img.naturalWidth,height:img.naturalHeight})}"
        "function resetPoints(){points=[];document.querySelectorAll('.dot').forEach(x=>x.remove());update()}"
        "async function copyResult(){result.select();try{await navigator.clipboard.writeText(result.value)}"
        "catch(e){document.execCommand('copy')}}img.onload=update;</script>", image_path);
    fclose(page);
    return 0;
}

static int prompt_line(const char *prompt, char *buffer, size_t capacity) {
    fputs(prompt, stdout);
    fflush(stdout);
    if (fgets(buffer, (int)capacity, stdin) == NULL) {
        return -1;
    }
    trim_line_ending(buffer);
    return buffer[0] == '\0' ? -1 : 0;
}

static int advance_challenges(atr_auth_session_t *session, atr_auth_challenge_t *challenge) {
    for (unsigned step = 0; step < 8; ++step) {
        if (challenge->kind == ATR_AUTH_CHALLENGE_DONE) {
            printf("[password-auth] authentication completed\n");
            return 0;
        }

        atr_auth_challenge_t next = {0};
        int code = 0;
        if (challenge->kind == ATR_AUTH_CHALLENGE_CAPTCHA) {
            char path[80];
            if (write_captcha(&challenge->image, path) != 0) {
                return -1;
            }
            char page_path[96];
            if (write_captcha_page(path, page_path) != 0) {
                unlink(path);
                return -1;
            }
            printf("[password-auth] graphical captcha required; opening click interface\n");
            pid_t child = fork();
            if (child == 0) {
                execl("/usr/bin/open", "open", page_path, (char *)NULL);
                _exit(127);
            }
            char captcha[1024];
            if (prompt_line("Captcha JSON: ", captcha, sizeof(captcha)) != 0) {
                unlink(path);
                unlink(page_path);
                fprintf(stderr, "error: captcha was not provided\n");
                return -1;
            }
            code = atr_auth_session_submit_captcha(session, captcha, &next);
            secure_clear(captcha);
            unlink(path);
            unlink(page_path);
        } else if (challenge->kind == ATR_AUTH_CHALLENGE_SMS_CODE) {
            printf("[password-auth] SMS verification required\n");
            char sms_code[256];
            if (prompt_line("SMS code: ", sms_code, sizeof(sms_code)) != 0) {
                fprintf(stderr, "error: SMS code was not provided\n");
                return -1;
            }
            code = atr_auth_session_submit_sms_code(session, sms_code, &next);
            secure_clear(sms_code);
        } else if (challenge->kind == ATR_AUTH_CHALLENGE_CALLBACK_URL) {
            fprintf(stderr, "[password-auth] server redirected password login to a web callback; URL omitted\n");
            return -1;
        } else {
            fprintf(stderr, "[password-auth] unknown challenge kind: %d\n", challenge->kind);
            return -1;
        }

        atr_auth_challenge_free(challenge);
        memset(challenge, 0, sizeof(*challenge));
        if (code != ATR_OK) {
            atr_auth_challenge_free(&next);
            return report_error("challenge submission", code);
        }
        *challenge = next;
    }

    fprintf(stderr, "[password-auth] too many authentication challenges\n");
    return -1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s PATH_TO_AUTH_FILE\n", argv[0]);
        return 2;
    }

    char *username = NULL;
    char *password = NULL;
    if (read_credentials(argv[1], &username, &password) != 0) {
        secure_clear(password);
        free(username);
        free(password);
        return 2;
    }

    atr_auth_config_t config = {
        .server_host = "ivpn.hit.edu.cn",
        .server_port = 443,
        .user_agent = kUserAgent,
        .client_type = "SDPClient",
        .platform = "Linux",
        .login_domain = "local",
        .preferred_auth_type = "auth/psw",
        .io_timeout_ms = 30000,
        .allow_insecure_tls = false,
    };

    atr_auth_session_t *session = NULL;
    int code = atr_auth_session_new(&config, &session);
    if (code != ATR_OK) {
        report_error("create auth session", code);
        goto failure;
    }

    atr_auth_method_list_t methods = {0};
    code = atr_auth_session_available_methods(session, &methods);
    if (code != ATR_OK) {
        report_error("load authentication methods", code);
        goto failure;
    }
    bool password_method_found = false;
    for (size_t index = 0; index < methods.len; ++index) {
        atr_auth_method_info_t *method = &methods.items[index];
        if (strcmp(method->login_domain, "local") == 0 &&
            strcmp(method->auth_type, "auth/psw") == 0) {
            password_method_found = true;
            break;
        }
    }
    atr_auth_method_list_free(&methods);
    if (!password_method_found) {
        fprintf(stderr, "[password-auth] server does not advertise local/auth/psw\n");
        goto failure;
    }
    printf("[password-auth] server advertises local password authentication\n");

    char device_id[33];
    make_device_id(device_id);
    atr_password_login_input_t input = {
        .username = username,
        .password = password,
        .login_domain = "local",
    };
    atr_auth_challenge_t challenge = {0};
    code = atr_auth_session_login_password(session, &input, device_id, &challenge);
    secure_clear(password);
    if (code != ATR_OK) {
        report_error("password login", code);
        atr_auth_challenge_free(&challenge);
        goto failure;
    }

    if (advance_challenges(session, &challenge) != 0) {
        atr_auth_challenge_free(&challenge);
        goto failure;
    }
    atr_auth_challenge_free(&challenge);

    atr_blob_t resource = {0};
    code = atr_auth_session_fetch_client_resource(session, &resource);
    if (code != ATR_OK) {
        report_error("fetch client resource after login", code);
        goto failure;
    }
    printf("[password-auth] verified session by fetching %zu resource bytes\n", resource.len);
    atr_blob_free(&resource);

    atr_auth_session_free(session);
    secure_clear(username);
    secure_clear(password);
    free(username);
    free(password);
    return 0;

failure:
    if (session != NULL) {
        atr_auth_session_free(session);
    }
    secure_clear(username);
    secure_clear(password);
    free(username);
    free(password);
    return 1;
}
C_SOURCE

echo "[password-auth] compiling ABI test client"
/usr/bin/clang \
    -std=c17 \
    -Wall \
    -Wextra \
    -Werror \
    -I "$HEADER_DIR" \
    "$WORK_DIR/password_auth.c" \
    -L "$LIB_DIR" \
    -lreatrust \
    -Wl,-rpath,"$LIB_DIR" \
    -o "$WORK_DIR/password-auth"

echo "[password-auth] testing ivpn.hit.edu.cn:443 with local/auth/psw"
"$WORK_DIR/password-auth" "$AUTH_FILE"
