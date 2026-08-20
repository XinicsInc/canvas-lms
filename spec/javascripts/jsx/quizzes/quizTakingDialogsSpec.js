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
import {
  getSubmitWarningMessage,
  decideLinkClick,
  decideSubmitAttempt,
  neutralizeUjsLinkAttributes,
  showQuizWarningDialog,
  cancelPendingWarning
} from 'quiz_taking_dialogs'

QUnit.module('getSubmitWarningMessage')

test('cantGoBack에서 현재 문항이 공란이면 blank 경고를 반환한다', () => {
  const msg = getSubmitWarningMessage({
    cantGoBack: true,
    currentQuestionAnswered: false,
    finalSubmitButtonClicked: false,
    unseenCount: 0,
    unansweredCount: 0
  })
  ok(/leave it blank/.test(msg))
})

test('최종 제출 + cantGoBack + 미열람 문항이 있으면 unseen 경고가 blank 경고보다 우선한다', () => {
  const msg = getSubmitWarningMessage({
    cantGoBack: true,
    currentQuestionAnswered: false,
    finalSubmitButtonClicked: true,
    unseenCount: 2,
    unansweredCount: 0
  })
  ok(/2 questions you haven't seen/.test(msg))
})

test('최종 제출 + 일반 퀴즈 + 미응답 문항이 있으면 unanswered 경고를 개수 보간과 함께 반환한다', () => {
  const msg = getSubmitWarningMessage({
    cantGoBack: false,
    currentQuestionAnswered: true,
    finalSubmitButtonClicked: true,
    unseenCount: 0,
    unansweredCount: 3
  })
  ok(/3 unanswered questions/.test(msg))
})

test('경고 조건이 없으면 null을 반환한다', () => {
  equal(
    getSubmitWarningMessage({
      cantGoBack: false,
      currentQuestionAnswered: true,
      finalSubmitButtonClicked: true,
      unseenCount: 0,
      unansweredCount: 0
    }),
    null
  )
})

test('최종 제출이 아니고 문항이 답변된 상태면 null을 반환한다', () => {
  equal(
    getSubmitWarningMessage({
      cantGoBack: true,
      currentQuestionAnswered: true,
      finalSubmitButtonClicked: false,
      unseenCount: 5,
      unansweredCount: 5
    }),
    null
  )
})

QUnit.module('decideLinkClick', {
  setup() {
    $('#fixtures').html(
      '<div class="ui-dialog"><a id="inDialog" href="/x">x</a></div>' +
        '<a id="noWarn" class="no-warning" href="/x">x</a>' +
        '<a id="preview" class="file_preview_link" href="/x">x</a>' +
        '<a id="ujs" href="/x" data-method="post">x</a>' +
        '<a id="hash" href="#top">x</a>' +
        '<a id="normal" href="/somewhere">x</a>'
    )
  },
  teardown() {
    $('#fixtures').empty()
  }
})

function freshState(overrides) {
  return {
    warningBypassLink: null,
    alreadyAcceptedNavigatingAway: false,
    ...overrides
  }
}

const EVT = {defaultPrevented: false, locationHref: 'http://c.test/quiz'}

test('jQuery UI 다이얼로그 내부 링크는 ignore', () => {
  equal(decideLinkClick(freshState(), $('#inDialog')[0], EVT), 'ignore')
})

test('no-warning 링크는 proceed하며 이탈 승인 플래그를 세운다', () => {
  const state = freshState()
  equal(decideLinkClick(state, $('#noWarn')[0], EVT), 'proceed')
  ok(state.alreadyAcceptedNavigatingAway)
})

test('파일 미리보기 링크는 ignore', () => {
  equal(decideLinkClick(freshState(), $('#preview')[0], EVT), 'ignore')
})

test('UJS 계열 링크(data-method 등)는 ignore (spec D2)', () => {
  equal(decideLinkClick(freshState(), $('#ujs')[0], EVT), 'ignore')
})

test('bypass 링크는 proceed하며 플래그를 소비하고 이탈 승인 상태를 만든다', () => {
  const link = $('#normal')[0]
  const state = freshState({warningBypassLink: link})
  equal(decideLinkClick(state, link, EVT), 'proceed')
  equal(state.warningBypassLink, null)
  ok(state.alreadyAcceptedNavigatingAway)
})

test('bypass는 정확히 1회만 통과한다 — 같은 링크의 두 번째 클릭은 다시 intercept (spec R7)', () => {
  const link = $('#normal')[0]
  const state = freshState({warningBypassLink: link})
  equal(decideLinkClick(state, link, EVT), 'proceed')
  equal(decideLinkClick(state, link, EVT), 'intercept')
})

test('bypass가 다른 요소를 가리키면 intercept이며 플래그는 소비되지 않는다', () => {
  const other = $('#hash')[0]
  const state = freshState({warningBypassLink: other})
  equal(decideLinkClick(state, $('#normal')[0], EVT), 'intercept')
  equal(state.warningBypassLink, other)
})

test('해시 링크는 ignore (기존 해시 예외 유지 — spec AC4)', () => {
  equal(decideLinkClick(freshState(), $('#hash')[0], EVT), 'ignore')
})

test('이미 preventDefault된 이벤트는 ignore', () => {
  equal(decideLinkClick(freshState(), $('#normal')[0], {...EVT, defaultPrevented: true}), 'ignore')
})

test('일반 링크는 intercept이며 상태를 바꾸지 않는다', () => {
  const state = freshState()
  equal(decideLinkClick(state, $('#normal')[0], EVT), 'intercept')
  notOk(state.alreadyAcceptedNavigatingAway)
})

test('보조키(ctrl/cmd/shift) 클릭은 ignore — 새 탭 열기는 이탈이 아니다', () => {
  equal(decideLinkClick(freshState(), $('#normal')[0], {...EVT, hasModifier: true}), 'ignore')
})

QUnit.module('decideSubmitAttempt')

test('[확인] 재제출 플래그가 있으면 proceed하며 플래그를 소비하고 submitting을 세운다 (spec R7)', () => {
  const state = {warningConfirmedSubmit: true, submitting: false}
  equal(decideSubmitAttempt(state, 'warn!'), 'proceed')
  notOk(state.warningConfirmedSubmit)
  ok(state.submitting)
})

test('플래그는 정확히 1회만 통과한다 — 경고가 남아 있으면 두 번째 시도는 다시 warn', () => {
  const state = {warningConfirmedSubmit: true, submitting: false}
  equal(decideSubmitAttempt(state, 'warn!'), 'proceed')
  state.submitting = false // 재제출 상황 재현
  equal(decideSubmitAttempt(state, 'warn!'), 'warn')
})

test('자동 제출(submitting=true 선세팅)은 경고를 우회한다 (spec D5 불변식)', () => {
  const state = {warningConfirmedSubmit: false, submitting: true}
  equal(decideSubmitAttempt(state, 'warn!'), 'proceed')
})

test('경고 메시지가 있고 제출 중이 아니면 warn이며 상태를 바꾸지 않는다', () => {
  const state = {warningConfirmedSubmit: false, submitting: false}
  equal(decideSubmitAttempt(state, 'warn!'), 'warn')
  notOk(state.submitting)
})

test('경고 메시지가 없으면 proceed하며 submitting을 세운다', () => {
  const state = {warningConfirmedSubmit: false, submitting: false}
  equal(decideSubmitAttempt(state, null), 'proceed')
  ok(state.submitting)
})

QUnit.module('neutralizeUjsLinkAttributes', {
  setup() {
    $('#fixtures').html(
      '<div id="quiz-instructions">' +
        '<a id="l1" href="#" data-confirm="Are you sure?" data-url="/x" data-remove=".row">x</a>' +
        '</div>' +
        '<div id="questions">' +
        '<a id="l2" href="/somewhere" data-method="post">go</a>' +
        '</div>' +
        '<div id="outside"><a id="l3" href="#" data-confirm="keep me">y</a></div>'
    )
  },
  teardown() {
    $('#fixtures').empty()
  }
})

test('루트 서브트리의 UJS 트리거 속성(data-confirm/method/remove)을 제거한다', () => {
  neutralizeUjsLinkAttributes($('#quiz-instructions, #questions'))
  equal($('#l1').attr('data-confirm'), undefined)
  equal($('#l1').attr('data-remove'), undefined)
  equal($('#l2').attr('data-method'), undefined)
})

test('루트 밖 링크는 건드리지 않는다', () => {
  neutralizeUjsLinkAttributes($('#quiz-instructions, #questions'))
  equal($('#outside a').attr('data-confirm'), 'keep me')
})

test('href와 UJS 외 속성은 보존한다', () => {
  neutralizeUjsLinkAttributes($('#quiz-instructions, #questions'))
  equal($('#l2').attr('href'), '/somewhere')
  equal($('#l1').attr('data-url'), '/x')
})

test('중화 후 판정 함수는 해당 링크를 일반 링크로 취급한다 (spec AC11 연결)', () => {
  neutralizeUjsLinkAttributes($('#quiz-instructions, #questions'))
  equal(decideLinkClick(freshState(), $('#l2')[0], EVT), 'intercept')
  equal(decideLinkClick(freshState(), $('#l1')[0], EVT), 'ignore') // href="#"는 해시 예외
})

QUnit.module('showQuizWarningDialog', {
  setup() {
    $('#fixtures').html(
      '<div style="display:none" id="quiz_warning_dialog">' +
        '<p class="quiz_warning_message"></p>' +
        '</div>'
    )
  },
  teardown() {
    cancelPendingWarning()
    const $d = $('#quiz_warning_dialog')
    if ($d.data('ui-dialog')) $d.dialog('destroy')
    $('#fixtures').empty()
  }
})

test('메시지를 텍스트로 표시하고 [확인] 클릭 시 onConfirm을 정확히 한 번 호출한다', () => {
  let calls = 0
  showQuizWarningDialog({
    message: '<b>3 unanswered</b>',
    confirmText: 'OK',
    onConfirm() {
      calls++
    }
  })
  // XSS 방지 — text()로 넣으므로 태그가 이스케이프되어야 한다
  equal($('.quiz_warning_message').text(), '<b>3 unanswered</b>')
  equal($('.quiz_warning_message').find('b').length, 0)
  $(".ui-dialog-buttonpane button:contains('OK')").click()
  equal(calls, 1)
  notOk($('#quiz_warning_dialog').dialog('isOpen'))
})

test('모달이 열리면 포커스가 모달 내부로 이동한다 (spec AC10 전반)', () => {
  showQuizWarningDialog({message: 'm', confirmText: 'OK', onConfirm() {}})
  ok($.contains($('.ui-dialog:visible')[0], document.activeElement))
})

test('[취소] 클릭 시 onConfirm을 호출하지 않고 닫는다', () => {
  let calls = 0
  showQuizWarningDialog({
    message: 'm',
    confirmText: 'OK',
    onConfirm() {
      calls++
    }
  })
  $(".ui-dialog-buttonpane button:contains('Cancel')").click()
  equal(calls, 0)
  notOk($('#quiz_warning_dialog').dialog('isOpen'))
})

test('ESC로 닫아도 onConfirm을 호출하지 않는다 (spec AC10)', () => {
  let calls = 0
  showQuizWarningDialog({
    message: 'm',
    confirmText: 'OK',
    onConfirm() {
      calls++
    }
  })
  const esc = $.Event('keydown', {keyCode: $.ui.keyCode.ESCAPE})
  $('#quiz_warning_dialog').trigger(esc)
  notOk($('#quiz_warning_dialog').dialog('isOpen'))
  equal(calls, 0)
})

test('cancelPendingWarning은 열려 있는 모달을 닫고 보류 콜백을 폐기한다', () => {
  let calls = 0
  showQuizWarningDialog({
    message: 'm',
    confirmText: 'OK',
    onConfirm() {
      calls++
    }
  })
  cancelPendingWarning()
  notOk($('#quiz_warning_dialog').dialog('isOpen'))
  equal(calls, 0)
})

test('모달이 열린 채 다시 호출하면 이전 콜백을 폐기하고 새 콜백으로 교체한다', () => {
  let first = 0
  let second = 0
  showQuizWarningDialog({
    message: 'a',
    confirmText: 'OK',
    onConfirm() {
      first++
    }
  })
  showQuizWarningDialog({
    message: 'b',
    confirmText: 'OK',
    onConfirm() {
      second++
    }
  })
  $(".ui-dialog-buttonpane button:contains('OK')").click()
  equal(first, 0)
  equal(second, 1)
})
