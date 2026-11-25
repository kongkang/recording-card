(function (global) {
  'use strict';

  var STORAGE_KEY = 'aicard_beta_verified_v2';
  var mountedControllers = [];

  var COPY = {
    zh: {
      emailPlaceholder: '你的 Apple ID 或常用邮箱，例如 you@icloud.com',
      iosWatchOption: 'iOS + Watch (TestFlight)',
      iosOption: 'iOS (TestFlight)',
      androidOption: 'Android (优先通知)',
      sendCode: '获取验证码',
      sending: '发送中…',
      step1Note: '验证邮箱后：iOS 自动触发苹果 TestFlight 邀请邮件 · Android 登记优先通知 · 均享早鸟福利',
      codeSentTo: '验证码已发送至 {email}（{platform}），10 分钟内有效。',
      codePlaceholder: '输入 6 位数字验证码',
      verifyBtn: '验证并获取邀请',
      verifying: '验证中…',
      resendCode: '重新发送验证码',
      resendWait: '重新发送 ({s}s)',
      changeEmail: '更换邮箱',
      errEmail: '请输入有效的邮箱地址',
      errCode: '请输入 6 位数字验证码',
      errNetwork: '网络异常，请稍后重试',
      doneTitleInvited: '✓ 邮箱已验证 · TestFlight 邀请已发送',
      doneDescInvited: '已向 {email} 发送苹果官方 TestFlight 邀请邮件（请留意收件箱或垃圾箱），并使用 iPhone 打开邮件接受安装；至少 1 个月会员与抽奖资格已为你保留。',
      doneTitleAlreadyInstalled: '✓ 邮箱已验证 · 已在 TestFlight 测试名单中',
      doneDescAlreadyInstalled: '检测到 {email} 已在录音卡 TestFlight 测试名单中，可直接在 iPhone 的「TestFlight」App 中安装，或点击下方公开链接加入（早鸟福利已保留）。',
      doneTitleQueued: '✓ 邮箱已验证 · 已加入 TestFlight 测试名单',
      doneDescQueued: '已验证并登记 {email}（第 {pos} 位）。当前构建正等待苹果外测审核，通过后苹果会自动发送安装邀请邮件。',
      doneTitleRetry: '! 邮箱已验证 · TestFlight 同步待重试',
      doneDescRetry: '你的邮箱 {email} 已验证，但连接苹果接口时暂时超时，请点击下方按钮重新发送邀请。',
      doneTitleAndroid: '✓ 邮箱已验证 · Android 优先通知已登记',
      doneDescAndroid: '已验证并登记 {email}（第 {pos} 位），并已发送确认邮件。Android 版本发布后第一时间通知你，早鸟福利已保留。',
      resendInvite: '重发 TestFlight 邀请',
      resendingInvite: '重发中…',
      publicLinkLabel: 'TestFlight 公开链接 ↗',
      resetBtn: '更换邮箱重新登记'
    },
    en: {
      emailPlaceholder: 'Your Apple ID or email, e.g. you@icloud.com',
      iosWatchOption: 'iOS + Watch (TestFlight)',
      iosOption: 'iOS (TestFlight)',
      androidOption: 'Android (Priority Waitlist)',
      sendCode: 'Send Verification Code',
      sending: 'Sending…',
      step1Note: 'After verifying: iOS automatically sends your Apple TestFlight invite · Android joins priority list · Early-bird perks included',
      codeSentTo: 'Sent a 6-digit code to {email} ({platform}). Valid for 10 minutes.',
      codePlaceholder: '6-digit verification code',
      verifyBtn: 'Verify & Get Invite',
      verifying: 'Verifying…',
      resendCode: 'Resend code',
      resendWait: 'Resend ({s}s)',
      changeEmail: 'Change email',
      errEmail: 'Please enter a valid email address.',
      errCode: 'Please enter the 6-digit numeric code.',
      errNetwork: 'Network error, please try again shortly.',
      doneTitleInvited: '✓ Email Verified · TestFlight Invite Sent',
      doneDescInvited: 'Apple has been triggered to send your TestFlight invite to {email} (check Spam/Junk too). Please accept it on your iPhone; your 1+ month membership & giveaway entry are locked in.',
      doneTitleAlreadyInstalled: '✓ Email Verified · Already in TestFlight Tester List',
      doneDescAlreadyInstalled: '{email} is already in the AI Card TestFlight tester list. Open TestFlight on your iPhone to install, or tap the public TestFlight link below.',
      doneTitleQueued: '✓ Email Verified · Registered for TestFlight',
      doneDescQueued: 'Verified {email} (#{pos}). The latest build is awaiting Apple Beta App Review; Apple will email your invite automatically once approved.',
      doneTitleRetry: '! Email Verified · Retry TestFlight Sync',
      doneDescRetry: 'Your email {email} is verified, but syncing with App Store Connect timed out. Click below to retry.',
      doneTitleAndroid: '✓ Email Verified · Android Waitlist Confirmed',
      doneDescAndroid: 'Verified {email} (#{pos}) and sent confirmation. We will email you as soon as the Android build is ready; early-bird perks are locked in.',
      resendInvite: 'Resend TestFlight Invite',
      resendingInvite: 'Resending…',
      publicLinkLabel: 'Public TestFlight Link ↗',
      resetBtn: 'Use a different email'
    }
  };

  function getSaved() {
    try {
      var raw = global.localStorage.getItem(STORAGE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (e) {
      return null;
    }
  }

  function setSaved(obj) {
    try {
      global.localStorage.setItem(STORAGE_KEY, JSON.stringify(obj));
    } catch (e) {}
  }

  function clearSaved() {
    try {
      global.localStorage.removeItem(STORAGE_KEY);
    } catch (e) {}
  }

  function apiPost(endpoint, body) {
    return global.fetch('/api/beta/' + endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    }).then(function (res) {
      return res.json().catch(function () {
        return { ok: false, message: 'Server returned invalid response' };
      }).then(function (data) {
        return { httpStatus: res.status, data: data };
      });
    });
  }

  function normalizePlatformValue(val) {
    var v = String(val || '').trim().toLowerCase();
    if (v === 'android') return 'android';
    if (v === 'ios') return 'ios';
    return 'iOS + Watch';
  }

  function mount(container, options) {
    if (!container) return null;
    var opts = options || {};
    var source = opts.source || container.getAttribute('data-wl-source') || 'web';
    var getLocaleFn = typeof opts.getLocale === 'function'
      ? opts.getLocale
      : function () { return opts.locale || 'zh'; };

    function langKey() {
      var l = String(getLocaleFn() || 'zh').toLowerCase();
      return l.indexOf('en') === 0 ? 'en' : 'zh';
    }

    function t(key) {
      var dict = COPY[langKey()] || COPY.zh;
      return dict[key] || COPY.zh[key] || '';
    }

    var state = {
      step: 'email',
      email: '',
      platform: 'iOS + Watch',
      status: '',
      position: null,
      publicUrl: '',
      canResendInvite: false,
      cooldownUntil: 0,
      busy: false,
      error: '',
      info: ''
    };

    var saved = getSaved();
    if (saved && saved.email && saved.status) {
      state.step = 'done';
      state.email = saved.email;
      state.platform = normalizePlatformValue(saved.platform);
      state.status = saved.status;
      state.position = saved.position || null;
      state.publicUrl = saved.publicUrl || '';
      state.canResendInvite = Boolean(saved.canResendInvite);
    }

    container.classList.add('rc-beta-root');
    container.innerHTML =
      '<div class="rc-beta-step" data-step="email">' +
        '<form class="rc-beta-form" novalidate>' +
          '<input class="rc-beta-hp" type="text" name="website" tabindex="-1" autocomplete="off" aria-hidden="true">' +
          '<div class="rc-beta-row">' +
            '<input class="rc-beta-input rc-beta-email" type="email" required autocomplete="email">' +
            '<select class="rc-beta-select rc-beta-platform" aria-label="Platform">' +
              '<option value="iOS + Watch"></option>' +
              '<option value="iOS"></option>' +
              '<option value="Android"></option>' +
            '</select>' +
            '<button class="rc-beta-btn rc-beta-submit-email" type="submit"></button>' +
          '</div>' +
          '<div class="rc-beta-err" aria-live="polite"></div>' +
          '<div class="rc-beta-note"></div>' +
        '</form>' +
      '</div>' +
      '<div class="rc-beta-step" data-step="code" hidden>' +
        '<div class="rc-beta-banner"></div>' +
        '<form class="rc-beta-form rc-beta-code-form" novalidate>' +
          '<div class="rc-beta-row rc-beta-row--code">' +
            '<input class="rc-beta-input rc-beta-code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" required>' +
            '<button class="rc-beta-btn rc-beta-submit-code" type="submit"></button>' +
          '</div>' +
          '<div class="rc-beta-actions">' +
            '<button class="rc-beta-link rc-beta-resend-code" type="button"></button>' +
            '<button class="rc-beta-link rc-beta-back" type="button"></button>' +
          '</div>' +
          '<div class="rc-beta-err" aria-live="polite"></div>' +
        '</form>' +
      '</div>' +
      '<div class="rc-beta-step rc-beta-done" data-step="done" hidden>' +
        '<div class="rc-beta-done-title"></div>' +
        '<div class="rc-beta-done-desc"></div>' +
        '<div class="rc-beta-info" aria-live="polite"></div>' +
        '<div class="rc-beta-err" aria-live="polite"></div>' +
        '<div class="rc-beta-actions">' +
          '<button class="rc-beta-btn rc-beta-btn--sm rc-beta-resend-invite" type="button" hidden></button>' +
          '<a class="rc-beta-link rc-beta-public-link" target="_blank" rel="noopener noreferrer" hidden></a>' +
          '<button class="rc-beta-link rc-beta-reset" type="button"></button>' +
        '</div>' +
      '</div>';

    var stepEmailEl = container.querySelector('[data-step="email"]');
    var stepCodeEl = container.querySelector('[data-step="code"]');
    var stepDoneEl = container.querySelector('[data-step="done"]');

    var emailForm = container.querySelector('.rc-beta-step[data-step="email"] form');
    var hpInput = container.querySelector('.rc-beta-hp');
    var emailInput = container.querySelector('.rc-beta-email');
    var platformSelect = container.querySelector('.rc-beta-platform');
    var submitEmailBtn = container.querySelector('.rc-beta-submit-email');
    var emailErr = stepEmailEl.querySelector('.rc-beta-err');
    var step1Note = stepEmailEl.querySelector('.rc-beta-note');

    var bannerEl = stepCodeEl.querySelector('.rc-beta-banner');
    var codeForm = stepCodeEl.querySelector('.rc-beta-code-form');
    var codeInput = stepCodeEl.querySelector('.rc-beta-code');
    var submitCodeBtn = stepCodeEl.querySelector('.rc-beta-submit-code');
    var resendCodeBtn = stepCodeEl.querySelector('.rc-beta-resend-code');
    var backBtn = stepCodeEl.querySelector('.rc-beta-back');
    var codeErr = stepCodeEl.querySelector('.rc-beta-err');

    var doneTitleEl = stepDoneEl.querySelector('.rc-beta-done-title');
    var doneDescEl = stepDoneEl.querySelector('.rc-beta-done-desc');
    var doneInfoEl = stepDoneEl.querySelector('.rc-beta-info');
    var doneErrEl = stepDoneEl.querySelector('.rc-beta-err');
    var resendInviteBtn = stepDoneEl.querySelector('.rc-beta-resend-invite');
    var publicLinkEl = stepDoneEl.querySelector('.rc-beta-public-link');
    var resetBtn = stepDoneEl.querySelector('.rc-beta-reset');

    var timerId = null;

    function stopTimer() {
      if (timerId !== null) {
        global.clearInterval(timerId);
        timerId = null;
      }
    }

    function updateCountdown() {
      var remain = Math.max(0, Math.ceil((state.cooldownUntil - Date.now()) / 1000));
      if (remain > 0) {
        resendCodeBtn.disabled = true;
        resendCodeBtn.textContent = t('resendWait').replace('{s}', String(remain));
      } else {
        resendCodeBtn.disabled = state.busy;
        resendCodeBtn.textContent = t('resendCode');
        stopTimer();
      }
    }

    function startCooldown(seconds) {
      state.cooldownUntil = Date.now() + (seconds || 60) * 1000;
      stopTimer();
      updateCountdown();
      timerId = global.setInterval(updateCountdown, 1000);
    }

    function platDisplay(plat) {
      var v = String(plat || '').toLowerCase();
      if (v === 'android') return t('androidOption');
      if (v === 'ios') return t('iosOption');
      return t('iosWatchOption');
    }

    function isAndroid(plat) {
      return String(plat || '').toLowerCase() === 'android';
    }

    function render() {
      emailInput.placeholder = t('emailPlaceholder');
      platformSelect.options[0].textContent = t('iosWatchOption');
      platformSelect.options[1].textContent = t('iosOption');
      platformSelect.options[2].textContent = t('androidOption');
      platformSelect.value = state.platform;
      submitEmailBtn.textContent = state.busy ? t('sending') : t('sendCode');
      submitEmailBtn.disabled = state.busy;
      step1Note.textContent = t('step1Note');

      codeInput.placeholder = t('codePlaceholder');
      submitCodeBtn.textContent = state.busy ? t('verifying') : t('verifyBtn');
      submitCodeBtn.disabled = state.busy;
      backBtn.textContent = t('changeEmail');
      backBtn.disabled = state.busy;
      bannerEl.textContent = t('codeSentTo')
        .replace('{email}', state.email)
        .replace('{platform}', platDisplay(state.platform));
      updateCountdown();

      stepEmailEl.hidden = state.step !== 'email';
      stepCodeEl.hidden = state.step !== 'code';
      stepDoneEl.hidden = state.step !== 'done';

      emailErr.textContent = state.step === 'email' ? state.error : '';
      codeErr.textContent = state.step === 'code' ? state.error : '';
      doneErrEl.textContent = state.step === 'done' ? state.error : '';
      doneInfoEl.textContent = state.step === 'done' ? state.info : '';

      if (state.step === 'done') {
        var pos = state.position ? String(state.position) : '1';
        var androidMode = isAndroid(state.platform) || state.status === 'android_waitlist';
        if (androidMode) {
          doneTitleEl.textContent = t('doneTitleAndroid');
          doneDescEl.textContent = t('doneDescAndroid').replace('{email}', state.email).replace('{pos}', pos);
        } else if (state.status === 'invited') {
          doneTitleEl.textContent = t('doneTitleInvited');
          doneDescEl.textContent = t('doneDescInvited').replace('{email}', state.email).replace('{pos}', pos);
        } else if (state.status === 'already_installed') {
          doneTitleEl.textContent = t('doneTitleAlreadyInstalled');
          doneDescEl.textContent = t('doneDescAlreadyInstalled').replace('{email}', state.email).replace('{pos}', pos);
        } else if (state.status === 'invite_failed') {
          doneTitleEl.textContent = t('doneTitleRetry');
          doneDescEl.textContent = t('doneDescRetry').replace('{email}', state.email).replace('{pos}', pos);
        } else {
          doneTitleEl.textContent = t('doneTitleQueued');
          doneDescEl.textContent = t('doneDescQueued').replace('{email}', state.email).replace('{pos}', pos);
        }

        var showResend = !androidMode && state.canResendInvite;
        resendInviteBtn.hidden = !showResend;
        resendInviteBtn.disabled = state.busy;
        resendInviteBtn.textContent = state.busy ? t('resendingInvite') : t('resendInvite');

        if (!androidMode && state.publicUrl) {
          publicLinkEl.hidden = false;
          publicLinkEl.href = state.publicUrl;
          publicLinkEl.textContent = t('publicLinkLabel');
        } else {
          publicLinkEl.hidden = true;
        }
        resetBtn.textContent = t('resetBtn');
        resetBtn.disabled = state.busy;
      }
    }

    function sendCodeRequest(email, platform) {
      state.busy = true;
      state.error = '';
      render();
      apiPost('request-code', {
        email: email,
        platform: platform,
        source: source,
        locale: langKey() === 'en' ? 'en' : 'zh-Hans',
        website: hpInput.value || ''
      }).then(function (res) {
        state.busy = false;
        if (!res.data || !res.data.ok) {
          state.error = (res.data && res.data.message) || t('errNetwork');
          if (res.data && res.data.retryAfter) {
            startCooldown(Number(res.data.retryAfter));
          }
          render();
          return;
        }
        state.email = res.data.email || email;
        state.step = 'code';
        state.error = '';
        codeInput.value = '';
        startCooldown(Number(res.data.cooldown || 60));
        render();
        codeInput.focus();
      }).catch(function () {
        state.busy = false;
        state.error = t('errNetwork');
        render();
      });
    }

    emailForm.addEventListener('submit', function (e) {
      e.preventDefault();
      if (state.busy) return;
      var email = (emailInput.value || '').trim().toLowerCase();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        state.error = t('errEmail');
        render();
        emailInput.focus();
        return;
      }
      state.platform = platformSelect.value || 'iOS + Watch';
      sendCodeRequest(email, state.platform);
    });

    codeForm.addEventListener('submit', function (e) {
      e.preventDefault();
      if (state.busy) return;
      var code = (codeInput.value || '').trim();
      if (!/^\d{6}$/.test(code)) {
        state.error = t('errCode');
        render();
        codeInput.focus();
        return;
      }
      state.busy = true;
      state.error = '';
      render();
      apiPost('verify', {
        email: state.email,
        code: code,
        platform: state.platform,
        source: source,
        locale: langKey() === 'en' ? 'en' : 'zh-Hans',
        website: hpInput.value || ''
      }).then(function (res) {
        state.busy = false;
        if (!res.data || !res.data.ok) {
          if (res.data && res.data.code === 'ASC_INVITE_FAILED') {
            var retrySnapshot = {
              email: res.data.email || state.email,
              platform: state.platform,
              status: 'invite_failed',
              position: res.data.position || null,
              publicUrl: '',
              canResendInvite: true
            };
            setSaved(retrySnapshot);
            syncAllFromSaved(retrySnapshot);
            return;
          }
          state.error = (res.data && res.data.message) || t('errNetwork');
          render();
          return;
        }
        var snapshot = {
          email: res.data.email || state.email,
          platform: res.data.platform || state.platform,
          status: res.data.status || 'queued_pending_review',
          position: res.data.position || null,
          publicUrl: res.data.publicTestFlightUrl || '',
          canResendInvite: Boolean(res.data.canResendInvite)
        };
        setSaved(snapshot);
        stopTimer();
        syncAllFromSaved(snapshot);
      }).catch(function () {
        state.busy = false;
        state.error = t('errNetwork');
        render();
      });
    });

    resendCodeBtn.addEventListener('click', function () {
      if (state.busy || Date.now() < state.cooldownUntil) return;
      sendCodeRequest(state.email, state.platform);
    });

    backBtn.addEventListener('click', function () {
      if (state.busy) return;
      stopTimer();
      state.step = 'email';
      state.error = '';
      emailInput.value = state.email;
      render();
      emailInput.focus();
    });

    resendInviteBtn.addEventListener('click', function () {
      if (state.busy) return;
      state.busy = true;
      state.error = '';
      state.info = '';
      render();
      apiPost('resend-invite', {
        email: state.email,
        locale: langKey() === 'en' ? 'en' : 'zh-Hans'
      }).then(function (res) {
        state.busy = false;
        if (!res.data || !res.data.ok) {
          state.error = (res.data && res.data.message) || t('errNetwork');
          render();
          return;
        }
        var snapshot = {
          email: state.email,
          platform: state.platform,
          status: res.data.status || state.status,
          position: res.data.position || state.position,
          publicUrl: res.data.publicTestFlightUrl || state.publicUrl,
          canResendInvite: res.data.canResendInvite !== undefined ? Boolean(res.data.canResendInvite) : true
        };
        setSaved(snapshot);
        state.status = snapshot.status;
        state.position = snapshot.position;
        state.publicUrl = snapshot.publicUrl;
        state.canResendInvite = snapshot.canResendInvite;
        state.info = res.data.message || '';
        render();
      }).catch(function () {
        state.busy = false;
        state.error = t('errNetwork');
        render();
      });
    });

    resetBtn.addEventListener('click', function () {
      if (state.busy) return;
      clearSaved();
      syncAllReset();
    });

    var controller = {
      refreshLocale: function () {
        render();
      },
      applySnapshot: function (snap) {
        stopTimer();
        state.busy = false;
        state.error = '';
        state.info = '';
        state.step = 'done';
        state.email = snap.email;
        state.platform = normalizePlatformValue(snap.platform);
        state.status = snap.status;
        state.position = snap.position || null;
        state.publicUrl = snap.publicUrl || '';
        state.canResendInvite = Boolean(snap.canResendInvite);
        render();
      },
      reset: function () {
        stopTimer();
        state.busy = false;
        state.error = '';
        state.info = '';
        state.step = 'email';
        state.status = '';
        render();
      }
    };

    mountedControllers.push(controller);
    render();
    return controller;
  }

  function syncAllFromSaved(snap) {
    mountedControllers.forEach(function (c) { c.applySnapshot(snap); });
  }

  function syncAllReset() {
    mountedControllers.forEach(function (c) { c.reset(); });
  }

  function refreshAllLocales() {
    mountedControllers.forEach(function (c) { c.refreshLocale(); });
  }

  global.AiCardBetaSignup = {
    mount: mount,
    refreshAllLocales: refreshAllLocales
  };
})(window);
