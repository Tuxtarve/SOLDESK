(function () {
  const LOGIN_CSS_PATH = '/css/user/login.css';
  const SIGNUP_CSS_PATH = '/css/user/signup.css';
  const CHECK_PHONE_API = '/api/read/auth/check-phone';
  const SIGNUP_API = '/api/write/auth/signup';
  const runtime = window.APP_RUNTIME || {};

  function ensureModalCss() {
    return Promise.all([
      runtime.ensureStyle(LOGIN_CSS_PATH),
      runtime.ensureStyle(SIGNUP_CSS_PATH)
    ]);
  }

  function closeSignupPage() {
    if (runtime.removeNodeById) {
      runtime.removeNodeById('login-modal-overlay');
    }
    if (runtime.unlockBodyScroll) {
      runtime.unlockBodyScroll();
    }
  }

  function goToLoginPage() {
    closeSignupPage();
    if (typeof window.openLoginPage === 'function') {
      window.openLoginPage();
      return true;
    }
    alert('로그인 화면을 불러오지 못했습니다.');
    return false;
  }

  function setFieldError(modal, field, message) {
    const target = modal.querySelector(`[data-error-for="${field}"]`);
    if (target) target.textContent = message || '';
  }

  function setCommonError(modal, message) {
    const target = modal.querySelector('.signup-common-error');
    if (target) target.textContent = message || '';
  }

  function clearErrors(modal) {
    modal.querySelectorAll('.signup-field-error').forEach((node) => {
      node.textContent = '';
    });
    setCommonError(modal, '');
  }

  function onlyDigits(value) {
    return String(value || '').replace(/\D/g, '');
  }

  function sanitizeName(value) {
    return String(value || '').replace(/[^가-힣a-zA-Z\s]/g, '');
  }

  function isValidPhone(phone) {
    return /^01[016789]\d{7,8}$/.test(String(phone || '').trim());
  }

  function isValidName(name) {
    return /^[가-힣a-zA-Z\s]{2,20}$/.test(String(name || '').trim());
  }

  function isValidPassword(password) {
    return String(password || '').trim().length >= 4;
  }

  async function requestPhoneDuplicate(phone) {
    try {
      const result = await runtime.postJson(CHECK_PHONE_API, { phone });
      const duplicated =
        result.duplicated === true ||
        result.duplicate === true ||
        result.exists === true ||
        result.found === true ||
        Number(result.count || 0) > 0;

      return {
        success: result.success !== false,
        duplicated,
        message: result.message || ''
      };
    } catch (error) {
      return {
        success: false,
        duplicated: false,
        message: error.message || '서버에 연결할 수 없습니다.'
      };
    }
  }

  async function requestSignup(phone, password, name) {
    try {
      return await runtime.postJson(SIGNUP_API, { phone, password, name });
    } catch (error) {
      return {
        success: false,
        status: error.status,
        message: error.message || '서버 오류가 발생했습니다.'
      };
    }
  }

  function buildSignupHtml() {
    const overlay = document.createElement('div');
    overlay.id = 'login-modal-overlay';
    overlay.className = 'login-modal-overlay';

    overlay.innerHTML = `
      <div class="login-modal signup-modal" role="dialog" aria-modal="true" aria-labelledby="signup-modal-title">
        <button type="button" class="login-modal-close" aria-label="닫기">×</button>

        <div class="login-modal-header signup-header">
          <h2 id="signup-modal-title" class="login-modal-title">회원가입</h2>
          <p class="login-modal-subtitle">회원 정보를 입력해 주세요.</p>
        </div>

        <form class="signup-form" novalidate>
          <div class="signup-form-group">
            <input type="text" name="phone" class="login-input signup-input" placeholder="핸드폰번호" inputmode="numeric" maxlength="11" />
            <div class="signup-field-error" data-error-for="phone"></div>
          </div>

          <div class="signup-form-group">
            <input type="password" name="password" class="login-input signup-input" placeholder="비밀번호" autocomplete="new-password" />
            <div class="signup-field-error" data-error-for="password"></div>
          </div>

          <div class="signup-form-group">
            <input type="text" name="name" class="login-input signup-input" placeholder="이름" maxlength="20" />
            <div class="signup-field-error" data-error-for="name"></div>
          </div>

          <div class="signup-common-error"></div>

          <div class="signup-button-row">
            <button type="submit" class="login-submit-button signup-submit-button">가입</button>
            <button type="button" class="signup-cancel-button">취소</button>
          </div>
        </form>
      </div>
    `;

    return overlay;
  }

  function bindEvents(overlay) {
    const closeButton = overlay.querySelector('.login-modal-close');
    const cancelButton = overlay.querySelector('.signup-cancel-button');
    const form = overlay.querySelector('.signup-form');
    const phoneInput = form.querySelector('input[name="phone"]');
    const passwordInput = form.querySelector('input[name="password"]');
    const nameInput = form.querySelector('input[name="name"]');
    const submitButton = form.querySelector('.signup-submit-button');
    let isComposingName = false;
    let isSubmitting = false;

    async function validatePhoneDuplicate() {
      const phone = phoneInput.value.trim();
      if (!phone) return '핸드폰번호를 입력하세요.';
      if (!isValidPhone(phone)) return '핸드폰번호를 확인하세요.';

      const result = await requestPhoneDuplicate(phone);
      if (!result.success) {
        return result.message || '서버와 통신할 수 없습니다.';
      }
      if (result.duplicated) {
        return '이미 사용 중인 핸드폰번호입니다.';
      }
      return '';
    }

    overlay.addEventListener('click', function (event) {
      if (event.target === overlay) {
        closeSignupPage();
      }
    });

    closeButton.addEventListener('click', closeSignupPage);
    cancelButton.addEventListener('click', goToLoginPage);

    phoneInput.addEventListener('input', function () {
      phoneInput.value = onlyDigits(phoneInput.value).slice(0, 11);
      clearErrors(overlay);
    });

    passwordInput.addEventListener('input', function () {
      clearErrors(overlay);
    });

    nameInput.addEventListener('compositionstart', function () {
      isComposingName = true;
    });

    nameInput.addEventListener('compositionend', function () {
      isComposingName = false;
      nameInput.value = sanitizeName(nameInput.value);
    });

    nameInput.addEventListener('input', function () {
      if (!isComposingName) {
        nameInput.value = sanitizeName(nameInput.value);
      }
      clearErrors(overlay);
    });

    form.addEventListener('submit', async function (event) {
      event.preventDefault();
      if (isSubmitting) return;

      clearErrors(overlay);

      const phone = phoneInput.value.trim();
      const password = passwordInput.value;
      const name = nameInput.value.trim();

      let hasError = false;
      if (!isValidPhone(phone)) {
        setFieldError(overlay, 'phone', '핸드폰번호를 확인하세요.');
        hasError = true;
      }
      if (!isValidPassword(password)) {
        setFieldError(overlay, 'password', '비밀번호는 4자 이상 입력하세요.');
        hasError = true;
      }
      if (!isValidName(name)) {
        setFieldError(overlay, 'name', '이름을 확인하세요.');
        hasError = true;
      }
      if (hasError) return;

      const phoneError = await validatePhoneDuplicate();
      if (phoneError) {
        setFieldError(overlay, 'phone', phoneError);
        return;
      }

      isSubmitting = true;
      submitButton.disabled = true;
      submitButton.textContent = '가입 중...';

      try {
        const result = await requestSignup(phone, password, name);
        if (result.success === false) {
          setCommonError(overlay, result.message || '회원가입에 실패했습니다.');
          return;
        }

        alert('회원가입이 완료되었습니다.');
        goToLoginPage();
      } finally {
        isSubmitting = false;
        submitButton.disabled = false;
        submitButton.textContent = '가입';
      }
    });
  }

  async function openSignupPage() {
    if (runtime.clearTransientUi) {
      runtime.clearTransientUi();
    }

    try {
      await ensureModalCss();
    } catch (error) {
      console.error('[signup] css load error:', error);
    }

    const overlay = buildSignupHtml();
    runtime.lockBodyScroll();
    document.body.appendChild(overlay);
    bindEvents(overlay);

    const firstInput = overlay.querySelector('input[name="phone"]');
    if (firstInput) {
      requestAnimationFrame(() => firstInput.focus());
    }
  }

  window.openSignupPage = openSignupPage;
  window.closeSignupPage = closeSignupPage;
})();
