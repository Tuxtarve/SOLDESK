(function () {
  const THEATERS_DETAIL_CSS_PATH = '/css/theaters/theaters_detail.css';
  const THEATERS_DETAIL_CSS_URL = `${THEATERS_DETAIL_CSS_PATH}?v=20260408_concert_base`;

  const CONCERT_MODAL_CSS_PATH = '/css/concert/concert_booking_modal.css';
  const CONCERT_MODAL_CSS_URL = `${CONCERT_MODAL_CSS_PATH}?v=20260408_concert_modal`;
  const OVERLAY_ID = 'concert-booking-detail-overlay';
  const BODY_ACTIVE_CLASS = 'theaters-booking-modal-open';

  function ensureDetailCss() {
    if (window.APP_RUNTIME && typeof window.APP_RUNTIME.ensureStyle === 'function') {
      return Promise.all([
        window.APP_RUNTIME.ensureStyle(THEATERS_DETAIL_CSS_URL),
        window.APP_RUNTIME.ensureStyle(CONCERT_MODAL_CSS_URL),
      ]);
    }
    const exists = document.querySelector(
      `link[href="${THEATERS_DETAIL_CSS_PATH}"], link[href="${THEATERS_DETAIL_CSS_URL}"]`
    );
    const existsConcert = document.querySelector(
      `link[href="${CONCERT_MODAL_CSS_PATH}"], link[href="${CONCERT_MODAL_CSS_URL}"]`
    );

    if (exists && existsConcert) return Promise.resolve([exists, existsConcert]);

    const links = [];

    if (!exists) {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = THEATERS_DETAIL_CSS_URL;
      document.head.appendChild(link);
      links.push(link);
    } else {
      links.push(exists);
    }

    if (!existsConcert) {
      const link = document.createElement('link');
      link.rel = 'stylesheet';
      link.href = CONCERT_MODAL_CSS_URL;
      document.head.appendChild(link);
      links.push(link);
    } else {
      links.push(existsConcert);
    }

    return Promise.resolve(links);
  }

  function escapeHtml(value) {
    if (value === null || value === undefined) return '';
    return String(value)
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
  }

  function toInt(value) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? Math.trunc(parsed) : 0;
  }

  function pad2(value) {
    return String(value).padStart(2, '0');
  }

  function parseDateValue(value) {
    if (!value) return null;
    const normalized = String(value).trim().replace(' ', 'T');
    const date = new Date(normalized);
    if (!Number.isNaN(date.getTime())) return date;
    const fallback = new Date(String(value).trim());
    return Number.isNaN(fallback.getTime()) ? null : fallback;
  }

  function addMinutes(value, minutes) {
    const date = parseDateValue(value);
    if (!date) return null;
    return new Date(date.getTime() + Number(minutes || 0) * 60 * 1000);
  }

  function formatTime(value) {
    const date = parseDateValue(value);
    if (!date) return '--:--';
    return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
  }

  function lockBodyScroll() {
    if (window.APP_RUNTIME && typeof window.APP_RUNTIME.lockBodyScroll === 'function') {
      window.APP_RUNTIME.lockBodyScroll();
      return;
    }
    document.body.classList.add(BODY_ACTIVE_CLASS);
    document.body.style.overflow = 'hidden';
  }

  function unlockBodyScroll() {
    if (window.APP_RUNTIME && typeof window.APP_RUNTIME.unlockBodyScroll === 'function') {
      window.APP_RUNTIME.unlockBodyScroll();
      return;
    }
    document.body.classList.remove(BODY_ACTIVE_CLASS);
    document.body.style.overflow = '';
  }

  function closeModal() {
    const overlay = document.getElementById(OVERLAY_ID);
    if (overlay) overlay.remove();
    unlockBodyScroll();
  }

  function getStoredUserId() {
    if (window.APP_RUNTIME && typeof window.APP_RUNTIME.getStoredUserId === 'function') {
      const raw = String(window.APP_RUNTIME.getStoredUserId() || '').trim();
      return /^\d+$/.test(raw) && Number(raw) > 0 ? raw : '';
    }
    const raw = String(localStorage.getItem('user_id') || sessionStorage.getItem('user_id') || '').trim();
    return /^\d+$/.test(raw) && Number(raw) > 0 ? raw : '';
  }

  function createSeatKey(row, col) {
    return `${row}-${col}`;
  }

  function createSeatLabel(row, col) {
    const rowNo = toInt(row);
    const rowLabel = rowNo === 1 ? 'A열' : rowNo === 2 ? 'B열' : rowNo === 3 ? 'C열' : `${rowNo}열`;
    return `${rowLabel} ${col}번`;
  }

  async function requestConcertBooking(payload) {
    if (typeof writeApi !== 'function') {
      throw new Error('writeApi가 없습니다.');
    }
    return await writeApi('/concerts/booking/commit', 'POST', payload);
  }

  async function openConcertBookingModal(options) {
    await ensureDetailCss();
    closeModal();
    lockBodyScroll();

    const data = options && typeof options === 'object' ? options : {};
    const show = data.show || {};
    const concert = data.concert || {};
    const onBooked = typeof data.onBooked === 'function' ? data.onBooked : function () {};
    const reservedSeats = new Set(
      Array.isArray(data.reservedSeats) ? data.reservedSeats.map((value) => String(value)) : []
    );

    const runtimeMinutes = toInt(concert.runtime_minutes || 120);
    const start = parseDateValue(show.show_date);
    const end = addMinutes(show.show_date, runtimeMinutes);

    const seatCols = Math.max(1, toInt(show.seat_cols) || 10);
    const seatRows = Math.max(1, toInt(show.seat_rows) || 5);
    const remainCount = Math.max(0, toInt(show.remain_count || 0));
    const totalCount = Math.max(0, toInt(show.total_count || 0)) || seatRows * seatCols;
    const price = Math.max(0, toInt(show.price || 0));
    const showId = toInt(show.show_id);

    const venueLine = [show.venue_name || '', show.hall_name || '홀'].filter(Boolean).join(' · ');

    const selectedSeats = new Set();
    let currentStep = 1;
    let lastResult = null;

    const overlay = document.createElement('div');
    overlay.id = OVERLAY_ID;
    overlay.className = 'theaters-detail-overlay';
    overlay.innerHTML = `
      <div class="theaters-detail-shell" role="dialog" aria-modal="true" aria-label="콘서트 예매">
        <nav class="theaters-detail-steps" aria-label="예매 단계">
          <button type="button" class="theaters-detail-step is-active" data-step="1" disabled tabindex="-1" aria-disabled="true">
            <span class="theaters-detail-step-no">01</span>
            <span class="theaters-detail-step-label">좌석선택</span>
          </button>
          <button type="button" class="theaters-detail-step" data-step="2" disabled tabindex="-1" aria-disabled="true">
            <span class="theaters-detail-step-no">02</span>
            <span class="theaters-detail-step-label">결제</span>
          </button>
          <button type="button" class="theaters-detail-step" data-step="3" disabled tabindex="-1" aria-disabled="true">
            <span class="theaters-detail-step-no">03</span>
            <span class="theaters-detail-step-label">결제완료</span>
          </button>
        </nav>

        <div class="theaters-detail-modal">
          <div class="theaters-detail-head">
            <div class="theaters-detail-title">${escapeHtml(formatTime(start))}~${escapeHtml(formatTime(end))} (${escapeHtml(show.hall_name || '회차')})</div>
            <button type="button" class="theaters-detail-close" aria-label="닫기">×</button>
          </div>

          <div class="theaters-detail-body">
            <div class="theaters-detail-summary">
              <div class="theaters-detail-movie">${escapeHtml(concert.title || '공연')}</div>
              <div class="theaters-detail-place">${escapeHtml(venueLine || '공연장')}</div>
              <div class="theaters-detail-date">${escapeHtml(String(show.show_date || '').slice(0, 16))}</div>
            </div>

            <section class="theaters-detail-panel theaters-detail-panel-seat" data-panel="1">
              <div class="theaters-detail-seat-count">잔여좌석 <strong class="theaters-detail-remain">${escapeHtml(String(remainCount))}</strong><span>/${escapeHtml(String(totalCount))}</span></div>
              <div class="theaters-detail-screen-label">STAGE</div>
              <div class="theaters-detail-screen-bar"></div>
              <div class="theaters-detail-seat-grid"></div>

              <div class="theaters-detail-selected-wrap">
                <div class="theaters-detail-selected-label">선택 좌석</div>
                <div class="theaters-detail-selected-value">없음</div>
              </div>

              <div class="theaters-detail-price-wrap">
                <div>선택 인원 <strong class="theaters-detail-count">0명</strong></div>
                <div>예상 금액 <strong class="theaters-detail-price">0원</strong></div>
              </div>
            </section>

            <section class="theaters-detail-panel theaters-detail-panel-confirm" data-panel="2" hidden>
              <div class="theaters-detail-confirm-title">선택 정보 확인</div>
              <div class="theaters-detail-confirm-list">
                <div class="theaters-detail-confirm-row"><span>공연</span><strong class="theaters-detail-confirm-movie"></strong></div>
                <div class="theaters-detail-confirm-row"><span>장소</span><strong class="theaters-detail-confirm-theater"></strong></div>
                <div class="theaters-detail-confirm-row"><span>홀</span><strong class="theaters-detail-confirm-hall"></strong></div>
                <div class="theaters-detail-confirm-row"><span>일시</span><strong class="theaters-detail-confirm-date"></strong></div>
                <div class="theaters-detail-confirm-row"><span>좌석</span><strong class="theaters-detail-confirm-seats"></strong></div>
                <div class="theaters-detail-confirm-row"><span>인원</span><strong class="theaters-detail-confirm-count"></strong></div>
                <div class="theaters-detail-confirm-row"><span>결제금액</span><strong class="theaters-detail-confirm-price"></strong></div>
              </div>
              <div class="theaters-detail-confirm-ask-row">
                <div class="theaters-detail-confirm-ask">결제를 진행하시겠습니까?</div>
                <button type="button" class="theaters-detail-reselect">좌석 재선택</button>
              </div>
            </section>

            <section class="theaters-detail-panel theaters-detail-panel-result" data-panel="3" hidden>
              <div class="theaters-detail-result-title">결제 결과</div>
              <div class="theaters-detail-result-message"></div>
            </section>
          </div>

          <div class="theaters-detail-actions">
            <button type="button" class="theaters-detail-cancel">취소</button>
            <button type="button" class="theaters-detail-submit">결제 진행</button>
          </div>
        </div>
      </div>
    `;

    document.body.appendChild(overlay);

    const closeButton = overlay.querySelector('.theaters-detail-close');
    const cancelButton = overlay.querySelector('.theaters-detail-cancel');
    const submitButton = overlay.querySelector('.theaters-detail-submit');
    const seatGrid = overlay.querySelector('.theaters-detail-seat-grid');
    const selectedValue = overlay.querySelector('.theaters-detail-selected-value');
    const selectedCount = overlay.querySelector('.theaters-detail-count');
    const selectedPrice = overlay.querySelector('.theaters-detail-price');
    const remainNode = overlay.querySelector('.theaters-detail-remain');
    const stepButtons = overlay.querySelectorAll('.theaters-detail-step');
    const seatPanel = overlay.querySelector('.theaters-detail-panel-seat');
    const confirmPanel = overlay.querySelector('.theaters-detail-panel-confirm');
    const resultPanel = overlay.querySelector('.theaters-detail-panel-result');
    const confirmMovie = overlay.querySelector('.theaters-detail-confirm-movie');
    const confirmTheater = overlay.querySelector('.theaters-detail-confirm-theater');
    const confirmHall = overlay.querySelector('.theaters-detail-confirm-hall');
    const confirmDate = overlay.querySelector('.theaters-detail-confirm-date');
    const confirmSeats = overlay.querySelector('.theaters-detail-confirm-seats');
    const confirmCount = overlay.querySelector('.theaters-detail-confirm-count');
    const confirmPrice = overlay.querySelector('.theaters-detail-confirm-price');
    const resultMessage = overlay.querySelector('.theaters-detail-result-message');
    const reselectButton = overlay.querySelector('.theaters-detail-reselect');

    function updateSummary() {
      const seatLabels = Array.from(selectedSeats).map((seatKey) => {
        const parts = seatKey.split('-');
        return createSeatLabel(parts[0], parts[1]);
      });

      selectedValue.textContent = seatLabels.length ? seatLabels.join(', ') : '없음';
      selectedCount.textContent = `${selectedSeats.size}명`;
      selectedPrice.textContent = `${(selectedSeats.size * price).toLocaleString('ko-KR')}원`;
      remainNode.textContent = String(Math.max(0, remainCount - selectedSeats.size));
      if (currentStep === 1) {
        submitButton.disabled = selectedSeats.size === 0;
      }
    }

    function updateConfirmPanel() {
      const seatLabels = Array.from(selectedSeats).map((seatKey) => {
        const parts = seatKey.split('-');
        return createSeatLabel(parts[0], parts[1]);
      });

      if (confirmMovie) confirmMovie.textContent = String(concert.title || '');
      if (confirmTheater) {
        confirmTheater.textContent = String(show.venue_address || show.venue_name || '');
      }
      if (confirmHall) confirmHall.textContent = String(show.hall_name || '');
      if (confirmDate) confirmDate.textContent = String(show.show_date || '').slice(0, 16);
      if (confirmSeats) confirmSeats.textContent = seatLabels.length ? seatLabels.join(', ') : '없음';
      if (confirmCount) confirmCount.textContent = `${selectedSeats.size}명`;
      if (confirmPrice) confirmPrice.textContent = `${(selectedSeats.size * price).toLocaleString('ko-KR')}원`;
    }

    function setStep(step) {
      currentStep = step;

      stepButtons.forEach((btn) => {
        const isActive = String(btn.getAttribute('data-step')) === String(step);
        btn.classList.toggle('is-active', isActive);
      });

      if (seatPanel) seatPanel.hidden = step !== 1;
      if (confirmPanel) confirmPanel.hidden = step !== 2;
      if (resultPanel) resultPanel.hidden = step !== 3;

      if (step === 1) {
        submitButton.textContent = '결제 진행';
        submitButton.disabled = selectedSeats.size === 0;
      } else if (step === 2) {
        submitButton.textContent = '확인';
        submitButton.disabled = selectedSeats.size === 0;
        updateConfirmPanel();
      } else {
        submitButton.textContent = '닫기';
        submitButton.disabled = false;
        if (resultMessage) {
          resultMessage.textContent = lastResult && lastResult.message ? lastResult.message : '';
        }
      }
    }

    function handleSeatClick(button, seatKey) {
      if (button.disabled) return;

      if (selectedSeats.has(seatKey)) {
        selectedSeats.delete(seatKey);
        button.classList.remove('is-selected');
      } else {
        if (selectedSeats.size >= Math.max(1, remainCount)) {
          alert('선택 가능한 좌석 수를 초과했습니다.');
          return;
        }
        selectedSeats.add(seatKey);
        button.classList.add('is-selected');
      }

      updateSummary();
    }

    function renderSmallGrid() {
      for (let row = 1; row <= seatRows; row += 1) {
        const rowWrap = document.createElement('div');
        rowWrap.className = 'theaters-detail-seat-row';

        const rowLabel = document.createElement('div');
        rowLabel.className = 'theaters-detail-seat-row-label';
        rowLabel.textContent = row === 1 ? 'A열' : row === 2 ? 'B열' : row === 3 ? 'C열' : `${row}열`;
        rowWrap.appendChild(rowLabel);

        const rowSeats = document.createElement('div');
        rowSeats.className = 'theaters-detail-seat-row-seats';

        for (let col = 1; col <= seatCols; col += 1) {
          const seatKey = createSeatKey(row, col);
          const seat = document.createElement('button');
          seat.type = 'button';
          seat.className = 'theaters-detail-seat';
          seat.textContent = String(col);
          seat.setAttribute('aria-label', createSeatLabel(row, col));

          if (reservedSeats.has(seatKey)) {
            seat.classList.add('is-disabled');
            seat.disabled = true;
          }

          seat.addEventListener('click', function () {
            handleSeatClick(seat, seatKey);
          });

          rowSeats.appendChild(seat);
        }

        rowWrap.appendChild(rowSeats);
        seatGrid.appendChild(rowWrap);
      }
    }

    function renderLargeGrid() {
      // Large venue: avoid 10k~100k DOM nodes.
      // UX: interpark-like seat selection -> legend + row buttons + seat number pages + jump search.
      const COLS_PER_PAGE = 80;
      const ROW_BUTTONS_PER_PAGE = 20;

      let activeRow = 1;
      let activeColPage = 1;
      let activeRowPage = 1;

      overlay.classList.add('is-large-venue');

      const controls = document.createElement('div');
      controls.className = 'concert-seat-controls';

      const legend = document.createElement('div');
      legend.className = 'concert-seat-legend';
      legend.innerHTML = `
        <span class="concert-seat-legend-item"><span class="concert-seat-dot"></span> 선택가능</span>
        <span class="concert-seat-legend-item"><span class="concert-seat-dot is-selected"></span> 선택</span>
        <span class="concert-seat-legend-item"><span class="concert-seat-dot is-disabled"></span> 예매완료</span>
      `;

      const rowButtonsWrap = document.createElement('div');
      rowButtonsWrap.className = 'concert-seat-row-buttons';

      const rowPaging = document.createElement('div');
      rowPaging.className = 'concert-seat-page';

      const rowPrev = document.createElement('button');
      rowPrev.type = 'button';
      rowPrev.className = 'theaters-booking-calendar-btn';
      rowPrev.textContent = '열 이전';

      const rowNext = document.createElement('button');
      rowNext.type = 'button';
      rowNext.className = 'theaters-booking-calendar-btn';
      rowNext.textContent = '열 다음';

      const pageInfo = document.createElement('div');
      pageInfo.className = 'concert-seat-page-info';

      const seatPaging = document.createElement('div');
      seatPaging.className = 'concert-seat-page';

      const prevBtn = document.createElement('button');
      prevBtn.type = 'button';
      prevBtn.className = 'theaters-booking-calendar-btn';
      prevBtn.textContent = '좌석 이전';

      const nextBtn = document.createElement('button');
      nextBtn.type = 'button';
      nextBtn.className = 'theaters-booking-calendar-btn';
      nextBtn.textContent = '좌석 다음';

      const jump = document.createElement('div');
      jump.className = 'concert-seat-jump';
      jump.innerHTML = `
        <span style="font-size:13px;color:#555;">좌석번호 이동</span>
        <input type="number" min="1" max="${seatCols}" placeholder="번호 입력">
        <button type="button" class="theaters-booking-calendar-btn">이동</button>
      `;

      rowPaging.appendChild(rowPrev);
      rowPaging.appendChild(rowNext);

      seatPaging.appendChild(prevBtn);
      seatPaging.appendChild(nextBtn);

      controls.appendChild(legend);
      controls.appendChild(rowPaging);
      controls.appendChild(rowButtonsWrap);
      controls.appendChild(pageInfo);
      controls.appendChild(seatPaging);
      controls.appendChild(jump);

      const rowWrap = document.createElement('div');
      rowWrap.className = 'theaters-detail-seat-row';

      const rowLabel = document.createElement('div');
      rowLabel.className = 'theaters-detail-seat-row-label';
      rowLabel.textContent = 'A열';
      rowWrap.appendChild(rowLabel);

      const rowSeats = document.createElement('div');
      rowSeats.className = 'theaters-detail-seat-row-seats';
      rowSeats.style.gridTemplateColumns = `repeat(${Math.min(COLS_PER_PAGE, 10)}, minmax(0, 1fr))`;
      rowWrap.appendChild(rowSeats);

      seatGrid.appendChild(controls);
      seatGrid.appendChild(rowWrap);

      function getRowLabel(row) {
        return row === 1 ? 'A열' : row === 2 ? 'B열' : row === 3 ? 'C열' : `${row}열`;
      }

      function renderRowButtons() {
        const totalRowPages = Math.max(1, Math.ceil(seatRows / ROW_BUTTONS_PER_PAGE));
        activeRowPage = Math.min(Math.max(activeRowPage, 1), totalRowPages);

        const startRow = (activeRowPage - 1) * ROW_BUTTONS_PER_PAGE + 1;
        const endRow = Math.min(seatRows, startRow + ROW_BUTTONS_PER_PAGE - 1);

        rowButtonsWrap.innerHTML = '';
        for (let r = startRow; r <= endRow; r += 1) {
          const btn = document.createElement('button');
          btn.type = 'button';
          btn.className = 'concert-seat-row-btn';
          btn.textContent = getRowLabel(r);
          if (r === activeRow) btn.classList.add('is-active');
          btn.addEventListener('click', function () {
            activeRow = r;
            activeColPage = 1;
            renderRowButtons();
            renderRowPage();
          });
          rowButtonsWrap.appendChild(btn);
        }

        rowPrev.disabled = activeRowPage <= 1;
        rowNext.disabled = activeRowPage >= totalRowPages;
      }

      function updateButtonsState(totalSeatPages) {
        prevBtn.disabled = activeColPage <= 1;
        nextBtn.disabled = activeColPage >= totalSeatPages;
      }

      function renderRowPage() {
        const totalSeatPages = Math.max(1, Math.ceil(seatCols / COLS_PER_PAGE));
        activeColPage = Math.min(Math.max(activeColPage, 1), totalSeatPages);

        const startCol = (activeColPage - 1) * COLS_PER_PAGE + 1;
        const endCol = Math.min(seatCols, startCol + COLS_PER_PAGE - 1);

        rowLabel.textContent = getRowLabel(activeRow);

        rowSeats.innerHTML = '';
        // keep grid visually dense
        const visibleCols = endCol - startCol + 1;
        rowSeats.style.gridTemplateColumns = `repeat(${Math.min(visibleCols, 10)}, minmax(0, 1fr))`;

        for (let col = startCol; col <= endCol; col += 1) {
          const seatKey = createSeatKey(activeRow, col);
          const seat = document.createElement('button');
          seat.type = 'button';
          seat.className = 'theaters-detail-seat';
          seat.textContent = String(col);
          seat.setAttribute('aria-label', createSeatLabel(activeRow, col));

          if (reservedSeats.has(seatKey)) {
            seat.classList.add('is-disabled');
            seat.disabled = true;
          }
          if (selectedSeats.has(seatKey)) {
            seat.classList.add('is-selected');
          }

          seat.addEventListener('click', function () {
            handleSeatClick(seat, seatKey);
          });

          rowSeats.appendChild(seat);
        }

        pageInfo.textContent = `선택: ${getRowLabel(activeRow)} / 좌석 ${startCol}~${endCol} (페이지 ${activeColPage}/${totalSeatPages})`;
        updateButtonsState(totalSeatPages);
      }

      rowPrev.addEventListener('click', function () {
        activeRowPage -= 1;
        renderRowButtons();
      });

      rowNext.addEventListener('click', function () {
        activeRowPage += 1;
        renderRowButtons();
      });

      prevBtn.addEventListener('click', function () {
        activeColPage -= 1;
        renderRowPage();
      });

      nextBtn.addEventListener('click', function () {
        activeColPage += 1;
        renderRowPage();
      });

      const jumpInput = jump.querySelector('input');
      const jumpBtn = jump.querySelector('button');
      if (jumpBtn) {
        jumpBtn.addEventListener('click', function () {
          const targetCol = toInt(jumpInput && jumpInput.value);
          if (targetCol <= 0 || targetCol > seatCols) {
            alert('좌석 번호가 올바르지 않습니다.');
            return;
          }
          activeColPage = Math.ceil(targetCol / COLS_PER_PAGE);
          renderRowPage();
        });
      }

      renderRowButtons();
      renderRowPage();
    }

    const totalSeats = seatRows * seatCols;
    if (totalSeats > 1500) {
      renderLargeGrid();
    } else {
      renderSmallGrid();
    }

    updateSummary();
    setStep(1);

    closeButton.addEventListener('click', closeModal);
    cancelButton.addEventListener('click', closeModal);

    overlay.addEventListener('click', function (event) {
      if (event.target === overlay) {
        closeModal();
      }
    });

    document.addEventListener(
      'keydown',
      function escHandler(event) {
        if (event.key === 'Escape') {
          document.removeEventListener('keydown', escHandler);
          closeModal();
        }
      },
      { once: true }
    );

    submitButton.addEventListener('click', async function () {
      if (currentStep === 1) {
        if (!selectedSeats.size) {
          alert('좌석을 먼저 선택해주세요.');
          return;
        }

        const userId = getStoredUserId();
        if (!userId) {
          alert('로그인이 필요합니다.');
          if (typeof window.openLoginPage === 'function') {
            window.openLoginPage();
          }
          return;
        }

        setStep(2);
        return;
      }

      if (currentStep === 2) {
        const userId = getStoredUserId();
        if (!userId) {
          alert('로그인이 필요합니다.');
          if (typeof window.openLoginPage === 'function') {
            window.openLoginPage();
          }
          return;
        }

        submitButton.disabled = true;
        submitButton.textContent = '처리 중...';

        try {
          const result = await requestConcertBooking({
            user_id: userId,
            show_id: showId,
            seats: Array.from(selectedSeats)
          });

          if (result && result.ok) {
            const bookingCode = result.booking_code ? String(result.booking_code) : '';
            lastResult = {
              ok: true,
              message: `${bookingCode ? `예매번호 : ${bookingCode}\n` : ''}결제에 성공했습니다.`
            };
            onBooked({
              show_id: showId,
              selectedSeats: Array.from(selectedSeats)
            });
          } else {
            const code = result && result.code ? String(result.code) : 'ERROR';
            if (code === 'DUPLICATE_SEAT') {
              lastResult = { ok: false, message: '중복좌석입니다.' };
            } else if (code === 'SOLD_OUT') {
              lastResult = { ok: false, message: '매진입니다.' };
            } else if (code === 'INVALID_SEAT' || code === 'BAD_SEAT_KEY') {
              lastResult = { ok: false, message: '좌석 정보가 올바르지 않습니다. 새로고침 후 다시 시도해주세요.' };
            } else {
              lastResult = { ok: false, message: '결제 실패' };
            }
          }

          setStep(3);
        } catch (error) {
          console.error(error);
          const status = error && error.status ? Number(error.status) : 0;
          const errData = error && error.data ? error.data : null;
          if (status === 400 && errData && errData.code) {
            const code = String(errData.code);
            if (code === 'INVALID_SEAT' || code === 'BAD_SEAT_KEY') {
              lastResult = { ok: false, message: '좌석 정보가 올바르지 않습니다. 새로고침 후 다시 시도해주세요.' };
            } else if (code === 'NO_SEATS') {
              lastResult = { ok: false, message: '좌석을 선택해주세요.' };
            } else {
              lastResult = { ok: false, message: '요청값이 올바르지 않습니다.' };
            }
          } else {
            lastResult = { ok: false, message: error && error.message ? error.message : '결제 실패' };
          }
          setStep(3);
        } finally {
          submitButton.disabled = false;
          submitButton.textContent = currentStep === 2 ? '확인' : submitButton.textContent;
        }

        return;
      }

      if (currentStep === 3) {
        closeModal();
      }
    });

    if (reselectButton) {
      reselectButton.addEventListener('click', function () {
        setStep(1);
      });
    }
  }

  window.openConcertBookingModal = openConcertBookingModal;
})();
