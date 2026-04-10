(function () {
  const LOGIN_CSS_PATH = '/css/user/login.css';
  const LOGIN_API = '/api/read/auth/login';
  const runtime = window.APP_RUNTIME || {};

  let isLoginSubmitting = false;

  function getRuntimeLoginUser() {
    return typeof runtime.getLoginUser === 'function' ? runtime.getLoginUser() : null;
  }

  function closeLoginPage() {
    if (typeof runtime.removeNodeById === 'function') {
      runtime.removeNodeById('login-modal-overlay');
    } else {
      const overlay = document.getElementById('login-modal-overlay');
      if (overlay) overlay.remove();
    }

    if (typeof runtime.unlockBodyScroll === 'function') {
      runtime.unlockBodyScroll();
    }

    isLoginSubmitting = false;
  }

  function clearErrors(modal) {
    modal.querySelectorAll('.login-field-error').forEach((node) => {
      node.textContent = '';
    });

    const commonError = modal.querySelector('.login-common-error');
    if (commonError) {
      commonError.textContent = '';
    }
  }

  function setFieldError(modal, field, message) {
    const target = modal.querySelector(`.login-field-error[data-error-for="${field}"]`);
    if (target) target.textContent = message || '';
  }

  function setCommonError(modal, message) {
    const target = modal.querySelector('.login-common-error');
    if (target) target.textContent = message || '';
  }

  function normalizeResponse(data) {
    if (!data || typeof data !== 'object') {
      return {
        success: false,
        commonMessage: '로그인 처리 중 오류가 발생했습니다.'
      };
    }

    if (data.message === 'login success' && data.user) {
      return {
        success: true,
        user: data.user
      };
    }

    if (data.message === 'invalid input') {
      return {
        success: false,
        fieldErrors: {
          phone: '전화번호를 입력해 주세요.',
          password: '비밀번호를 입력해 주세요.'
        }
      };
    }

    if (data.message === '전화번호가 틀립니다.') {
      return {
        success: false,
        fieldErrors: {
          phone: '전화번호가 틀립니다.'
        }
      };
    }

    if (data.message === '비밀번호가 틀립니다.') {
      return {
        success: false,
        fieldErrors: {
          password: '비밀번호가 틀립니다.'
        }
      };
    }

    return {
      success: false,
      commonMessage: data.message || '서버와 통신 중 문제가 발생했습니다.'
    };
  }

  async function requestLogin(phone, password) {
    try {
      const data = await runtime.postJson(LOGIN_API, { phone, password });
      return normalizeResponse(data);
    } catch (error) {
      console.error('login fetch error:', error);
      if (error && error.data) {
        return normalizeResponse(error.data);
      }
      return {
        success: false,
        commonMessage: error.message || '서버와 통신 중 문제가 발생했습니다.'
      };
    }
  }

  async function openPwFindPage() {
    try {
      if (typeof runtime.ensureScript === 'function') {
        await runtime.ensureScript('/js/user/pwfind.js');
      }
      closeLoginPage();

      if (typeof window.openPwFindPage === 'function') {
        window.openPwFindPage();
        return;
      }

      alert('PW 찾기 화면을 불러오지 못했습니다.');
    } catch (error) {
      console.error('pwfind.js load error:', error);
      alert('PW 찾기 화면을 불러오지 못했습니다.');
    }
  }

  async function openSignupPage() {
    try {
      if (typeof runtime.ensureScript === 'function') {
        await runtime.ensureScript('/js/user/signup.js');
      }
      closeLoginPage();

      if (typeof window.openSignupPage === 'function') {
        window.openSignupPage();
        return;
      }

      alert('회원가입 화면을 불러오지 못했습니다.');
    } catch (error) {
      console.error('signup.js load error:', error);
      alert('회원가입 화면을 불러오지 못했습니다.');
    }
  }

  function buildModalHtml() {
    const rememberedLoginId = typeof runtime.getRememberedLoginId === 'function'
      ? runtime.getRememberedLoginId()
      : '';
    const isRemembered = rememberedLoginId !== '';

    const overlay = document.createElement('div');
    overlay.id = 'login-modal-overlay';
    overlay.className = 'login-modal-overlay';

    overlay.innerHTML = `
      <div class="login-modal" role="dialog" aria-modal="true" aria-labelledby="login-modal-title">
        <button type="button" class="login-modal-close" aria-label="닫기">×</button>

        <div class="login-modal-header">
          <h2 id="login-modal-title" class="login-modal-title">LOGIN</h2>
          <p class="login-modal-subtitle">서비스 이용을 위해 로그인해 주세요.</p>
        </div>

        <form class="login-form" novalidate>
          <div class="login-form-group">
            <input
              type="text"
              name="phone"
              class="login-input"
              placeholder="전화번호"
              autocomplete="username"
              inputmode="numeric"
              maxlength="11"
              value="${rememberedLoginId}"
            />
            <div class="login-field-error" data-error-for="phone"></div>
          </div>

          <div class="login-form-group">
            <input
              type="password"
              name="password"
              class="login-input"
              placeholder="비밀번호"
              autocomplete="current-password"
            />
            <div class="login-field-error" data-error-for="password"></div>
          </div>

          <label class="login-keep-wrap">
            <input type="checkbox" name="remember_id" class="login-keep-checkbox" ${isRemembered ? 'checked' : ''} />
            <span>아이디 기억</span>
          </label>

          <div class="login-common-error"></div>

          <button type="submit" class="login-submit-button">로그인</button>

          <div class="login-modal-links">
            <button type="button" class="login-link-button" data-action="pwfind">PW 찾기</button>
            <span class="login-link-divider">|</span>
            <button type="button" class="login-link-button" data-action="signup">회원가입</button>
          </div>
        </form>
      </div>
    `;

    return overlay;
  }

  function bindModalEvents(overlay) {
    const closeButton = overlay.querySelector('.login-modal-close');
    const form = overlay.querySelector('.login-form');
    const phoneInput = overlay.querySelector('input[name="phone"]');
    const pwInput = overlay.querySelector('input[name="password"]');
    const rememberIdInput = overlay.querySelector('input[name="remember_id"]');
    const linkButtons = overlay.querySelectorAll('.login-link-button');
    const submitButton = form.querySelector('.login-submit-button');

    closeButton.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();
      closeLoginPage();
    });

    overlay.addEventListener('click', function (event) {
      if (event.target === overlay) {
        closeLoginPage();
      }
    });

    phoneInput.addEventListener('input', function () {
      phoneInput.value = phoneInput.value.replace(/\D/g, '').slice(0, 11);
      setFieldError(overlay, 'phone', '');
      setCommonError(overlay, '');
    });

    pwInput.addEventListener('input', function () {
      setFieldError(overlay, 'password', '');
      setCommonError(overlay, '');
    });

    linkButtons.forEach((button) => {
      button.addEventListener('click', function () {
        const action = button.dataset.action;
        if (action === 'pwfind') {
          openPwFindPage();
          return;
        }
        if (action === 'signup') {
          openSignupPage();
        }
      });
    });

    form.addEventListener('submit', async function (event) {
      event.preventDefault();
      if (isLoginSubmitting) return;

      clearErrors(overlay);

      const phone = phoneInput.value.trim();
      const password = pwInput.value;
      const rememberId = rememberIdInput.checked;

      let hasError = false;
      if (!phone) {
        setFieldError(overlay, 'phone', '전화번호를 입력해 주세요.');
        hasError = true;
      }
      if (!password) {
        setFieldError(overlay, 'password', '비밀번호를 입력해 주세요.');
        hasError = true;
      }
      if (hasError) return;

      isLoginSubmitting = true;
      submitButton.disabled = true;
      submitButton.textContent = '로그인 중...';

      try {
        const result = await requestLogin(phone, password);
        if (!result.success) {
          if (result.fieldErrors?.phone) {
            setFieldError(overlay, 'phone', result.fieldErrors.phone);
          }
          if (result.fieldErrors?.password) {
            setFieldError(overlay, 'password', result.fieldErrors.password);
          }
          if (result.commonMessage) {
            setCommonError(overlay, result.commonMessage);
          }
          return;
        }

        if (rememberId) {
          runtime.saveRememberedLoginId(phone);
        } else {
          runtime.clearRememberedLoginId();
        }

        runtime.setLoginUser(result.user);
        closeLoginPage();

        if (typeof window.refreshSiteHeader === 'function') {
          await window.refreshSiteHeader();
        }

        if (typeof window.appPrefetchScripts === 'function') {
          window.appPrefetchScripts(['/js/user/mypage.js', '/js/user/edit.js', '/js/user/changepw.js']);
        }
      } catch (error) {
        console.error('login error:', error);
        setCommonError(overlay, '서버와 통신 중 문제가 발생했습니다.');
      } finally {
        isLoginSubmitting = false;
        submitButton.disabled = false;
        submitButton.textContent = '로그인';
      }
    });
  }

  async function openLoginPage() {
    const currentUser = getRuntimeLoginUser();
    if (currentUser) {
      if (typeof window.appNavigate === 'function') {
        window.appNavigate({ view: 'mypage' });
      }
      return;
    }

    if (typeof runtime.clearTransientUi === 'function') {
      runtime.clearTransientUi();
    }

    try {
      await runtime.ensureStyle(LOGIN_CSS_PATH);
    } catch (error) {
      console.error('login css load error:', error);
    }

    const overlay = buildModalHtml();
    runtime.lockBodyScroll();
    document.body.appendChild(overlay);
    bindModalEvents(overlay);

    const firstInput = overlay.querySelector('input[name="phone"]');
    if (firstInput) {
      requestAnimationFrame(() => firstInput.focus());
    }
  }

  function logoutUser() {
    if (typeof runtime.clearLoginUser === 'function') {
      runtime.clearLoginUser();
    }
    closeLoginPage();

    if (typeof window.refreshSiteHeader === 'function') {
      window.refreshSiteHeader();
    }

    alert('로그아웃 되었습니다.');

    if (typeof window.appNavigate === 'function') {
      window.appNavigate({}, { replace: true });
      return;
    }

    window.location.href = '/';
  }

  window.openLoginPage = openLoginPage;
  window.closeLoginPage = closeLoginPage;
  window.getLoginUser = function () {
    return runtime.getLoginUser ? runtime.getLoginUser() : null;
  };
  window.clearLoginUser = function () {
    if (runtime.clearLoginUser) {
      runtime.clearLoginUser();
    }
  };
  window.logoutUser = logoutUser;
})();
