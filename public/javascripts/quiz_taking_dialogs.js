/*
 * Copyright (C) 2026 - present Instructure, Inc.
 *
 * This file is part of Canvas.
 *
 * Canvas is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Affero General Public License as published by the Free
 * Software Foundation, version 3 of the License.
 *
 * Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 * A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
 * details.
 *
 * You should have received a copy of the GNU Affero General Public License along
 * with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import $ from 'jquery'
import I18n from 'i18n!quizzes.take_quiz'
import 'jqueryui/dialog'

// PRT-109: 응시 중 브라우저 네이티브 다이얼로그 제거를 위한 헬퍼 모듈.
// spec: docs/superpowers/specs/2026-08-18-PRT-109-spec.md

// 응시 본문에서 UJS 트리거 속성을 제거한다 (spec D2 중화).
// user_content()는 .user_content 클래스 밖에도 렌더링되므로
// 클래스 셀렉터가 아니라 #quiz-instructions·#questions 서브트리 기준으로 호출해야 한다.
export function neutralizeUjsLinkAttributes($roots) {
  $roots.find('a[data-confirm], a[data-method], a[data-remove]').each(function() {
    $(this)
      .removeAttr('data-confirm')
      .removeAttr('data-method')
      .removeAttr('data-remove')
      .removeData('confirm')
      .removeData('method')
      .removeData('remove')
  })
}

// 응시 중 링크 클릭 판정 + 상태 전이 (take_quiz.js 링크 delegate의 판단부).
// 기존 핸들러(원 614–649행)의 예외 순서를 그대로 보존한다.
// state는 quizSubmission 객체 — warningBypassLink·alreadyAcceptedNavigatingAway를 읽고 쓴다.
// - 'ignore'    통과, 상태 전이 없음 (다이얼로그 내부·파일 미리보기·UJS·이미 prevented·해시)
// - 'proceed'   통과, 상태 전이 수행 (no-warning: 이탈 승인 / bypass: 플래그 1회 소비 + 이탈 승인)
// - 'intercept' 이탈 경고 모달 표시 대상
export function decideLinkClick(state, link, {defaultPrevented, locationHref}) {
  const $link = $(link)
  if ($link.closest('.ui-dialog,.mceToolbar,.ui-selectmenu').length > 0) return 'ignore'
  if ($link.hasClass('no-warning')) {
    state.alreadyAcceptedNavigatingAway = true
    return 'proceed'
  }
  if ($link.hasClass('file_preview_link')) return 'ignore'
  // UJS 계열은 인터셉트하지 않는다 (spec D2 — ujsLinks와의 바인딩 순서 비결정)
  if ($link.is('[data-method], [data-confirm], [data-remove]')) return 'ignore'
  if (state.warningBypassLink === link) {
    // [계속]으로 재발행된 클릭: 정확히 1회만 통과 (재진입 방지, spec R7)
    state.warningBypassLink = null
    state.alreadyAcceptedNavigatingAway = true
    return 'proceed'
  }
  if (defaultPrevented) return 'ignore'
  const url = $link.attr('href') || ''
  let hashStripped = locationHref
  if (hashStripped.indexOf('#')) {
    hashStripped = hashStripped.substring(0, hashStripped.indexOf('#'))
  }
  if (url.indexOf('#') === 0 || url.indexOf(hashStripped + '#') === 0) return 'ignore'
  return 'intercept'
}

// 제출 시도 판정 + 상태 전이 (take_quiz.js 제출 핸들러의 판단부).
// state는 quizSubmission 객체 — warningConfirmedSubmit·submitting을 읽고 쓴다.
// - 'proceed' 제출 진행 ([확인] 재제출 플래그 1회 소비 포함, submitting 세팅)
// - 'warn'    경고 모달 표시 대상 (상태 전이 없음)
// 자동 제출(시간 만료·end_at 폴백)은 submitting=true를 먼저 세우므로 'proceed'가 된다 —
// 기존 경고 우회 불변식 보존 (spec D5).
export function decideSubmitAttempt(state, warningMessage) {
  if (state.warningConfirmedSubmit) {
    state.warningConfirmedSubmit = false
    state.submitting = true
    return 'proceed'
  }
  if (warningMessage != null && !state.submitting) return 'warn'
  state.submitting = true
  return 'proceed'
}

// 제출 시 경고 메시지 결정. take_quiz.js 제출 핸들러의 분기(원 872–911행)를
// 우선순위 그대로 순수 함수로 옮긴 것 — 반환 null이면 경고 없음.
export function getSubmitWarningMessage({
  cantGoBack,
  currentQuestionAnswered,
  finalSubmitButtonClicked,
  unseenCount,
  unansweredCount
}) {
  let warningMessage = null

  if (cantGoBack && !currentQuestionAnswered) {
    warningMessage = I18n.t(
      'confirms.cant_go_back_blank',
      "You can't come back to this question once you hit next. Are you sure you want to leave it blank?"
    )
  }

  if (finalSubmitButtonClicked) {
    if (cantGoBack) {
      if (unseenCount > 0) {
        warningMessage = I18n.t(
          'confirms.unseen_questions',
          {
            one: "There is still 1 question you haven't seen yet.  Submit anyway?",
            other: "There are still %{count} questions you haven't seen yet.  Submit anyway?"
          },
          {count: unseenCount}
        )
      }
    } else if (unansweredCount > 0) {
      warningMessage = I18n.t(
        'confirms.unanswered_questions',
        {
          one:
            'You have 1 unanswered question (see the right sidebar for details).  Submit anyway?',
          other:
            'You have %{count} unanswered questions (see the right sidebar for details).  Submit anyway?'
        },
        {count: unansweredCount}
      )
    }
  }

  return warningMessage
}

// 열려 있는 확인 모달의 보류 콜백. 한 번에 하나만 유지한다.
let pendingConfirm = null

// 페이지 내부 확인 모달 (spec D1 — #times_up_dialog/#deauthorized_dialog와 동일한 jQuery UI 방식).
// 네이티브 confirm과 달리 비동기이므로, 호출측은 원래 동작을 막아두고
// onConfirm에서 정확히 한 번 재개해야 한다 (spec D2).
export function showQuizWarningDialog({message, confirmText, onConfirm}) {
  cancelPendingWarning()
  const $dialog = $('#quiz_warning_dialog')
  // i18n 문자열이지만 방어적으로 text()로 삽입한다 (HTML 해석 금지)
  $dialog.find('.quiz_warning_message').text(message)
  pendingConfirm = {onConfirm}
  $dialog.dialog({
    title: I18n.t('titles.quiz_warning', 'Attention'),
    modal: true,
    width: 400,
    resizable: false,
    buttons: [
      {
        text: I18n.t('#buttons.cancel', 'Cancel'),
        click() {
          $dialog.dialog('close')
        }
      },
      {
        class: 'btn-primary',
        text: confirmText,
        click() {
          const pending = pendingConfirm
          pendingConfirm = null
          $dialog.dialog('close')
          if (pending) pending.onConfirm()
        }
      }
    ],
    // 취소·ESC·X 등 어떤 경로로 닫혀도 보류 콜백은 폐기한다
    close() {
      pendingConfirm = null
    }
  })
  if (!$dialog.dialog('isOpen')) $dialog.dialog('open')
}

// 시간 만료(times_up) 등 외부 사유로 확인 모달을 강제 종료할 때 사용 (spec D5).
export function cancelPendingWarning() {
  pendingConfirm = null
  const $dialog = $('#quiz_warning_dialog')
  if ($dialog.data('ui-dialog') && $dialog.dialog('isOpen')) {
    $dialog.dialog('close')
  }
}
