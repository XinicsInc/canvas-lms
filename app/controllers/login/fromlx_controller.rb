#
# Copyright (C) 2024 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class Login::FromlxController < Login::CanvasController
  # Canvas에 'fromlx' auth provider가 존재하지 않으므로
  # validate_auth_type이 실행되면 ActiveRecord::RecordNotFound가 발생한다.
  # 이 엔드포인트는 Canvas local login 계열의 변형이므로 skip 필수.
  skip_before_action :validate_auth_type

  def create
    # /login/canvas 와 동일한 referer / authenticity token 정책 유지
    if params.key?(request_forgery_protection_token) || !@domain_root_account.trusted_referer?(request.referer)
      begin
        verify_authenticity_token
      rescue ActionController::InvalidAuthenticityToken
        Rails.logger.warn("LearningX login error: Invalid Authenticity Token")
        return unsuccessful_login(t("Invalid Authenticity Token"))
      end
    end

    # /login/canvas 와 동일하게 세션 고정 공격 방지를 위해 먼저 세션을 리셋
    reset_session_for_login

    encrypted = params[:result]
    if encrypted.blank?
      Rails.logger.warn("LearningX login error: Missing result parameter")
      return unsuccessful_login(t("No login token was given"))
    end

    payload = decrypt_payload(encrypted)
    unless payload.is_a?(Hash) && payload.key?('timestamp') && payload.key?('login_nonce') && payload.key?('user_login')
      Rails.logger.warn("LearningX login error: Invalid or malformed token payload")
      return unsuccessful_login(t("Invalid login token"))
    end

    # timestamp 검증 (±30초)
    unless valid_timestamp?(payload['timestamp'])
      Rails.logger.warn("LearningX login error: Expired token")
      return unsuccessful_login(t("Expired login token"))
    end

    # nonce 재사용 방지 (공유 Redis-backed Rails.cache, 60초 TTL)
    # 모든 웹 노드가 동일 Redis를 사용해야 하며,
    # read -> write 두 단계로 나누지 말고 NX 성격의 단일 원자 연산으로 처리한다.
    # Redis circuit open 시에도 fail-closed (로그인 거부) 유지.
    unless mark_nonce_used_once!(payload['login_nonce'])
      Rails.logger.warn("LearningX login error: Replayed or unverifiable token")
      return unsuccessful_login(t("Login temporarily unavailable. Please try again."))
    end

    unique_id = payload['user_login'].to_s
    unique_id.strip!
    if unique_id.blank?
      Rails.logger.warn("LearningX login error: Missing user_login")
      return unsuccessful_login(t("No user id was given"))
    end

    # /login/canvas 와 동일하게, root account 먼저 시도 후 trusted accounts fallback.
    # fallback 시에도 custom_find_by_unique_id 와 같은 provider 제약(canvas/ldap)을 유지하고,
    # Pseudonym.authenticate 와 같은 중복 선택 규칙(단일 사용자 또는 site_admin)을 적용한다.
    pseudonym = @domain_root_account.pseudonyms.scoping do
      Pseudonym.custom_find_by_unique_id(unique_id)
    end
    if pseudonym.nil?
      pseudonym = find_trusted_pseudonym(unique_id)
    end

    if pseudonym && (!pseudonym.user || pseudonym.user.unavailable?)
      return unsuccessful_login(t("That user account has been deleted.  Please contact your system administrator to have your account re-activated."))
    end

    if pseudonym
      # /login/canvas 의 trusted account fallback(line 102-109)과 동일하게,
      # root account pseudonym만 scoping 적용, trusted account pseudonym은 scoping 없이 생성.
      if pseudonym.account_id == @domain_root_account.id
        @domain_root_account.pseudonyms.scoping do
          PseudonymSession.create!(pseudonym, false)
        end
      else
        PseudonymSession.create!(pseudonym, false)
      end

      user = pseudonym.login_assertions_for_user

      session[:login_aac] ||= pseudonym.authentication_provider_id ||
        pseudonym.ldap_authentication_provider_used&.id ||
        @domain_root_account.canvas_authentication_provider&.id

      if payload['after_login_url'].present?
        session[:return_to] = payload['after_login_url']
      end

      successful_login(user, pseudonym)
    else
      unsuccessful_login(t("Invalid username or password"))
    end
  end

  protected

  # 이거 영 찜찜하다. 일부 통합로그인 사이트의 경우 무한 리다이렉트 루프 돌 수도 있겠는데...
  # 그렇다고 /login/canvas 화면이 표시되는 것도 곤란하고...
  #
  # 부모의 unsuccessful_login 은 /login/canvas 폼을 렌더링하지만,
  # fromlx 실패 시 자동 discovery 기반 통합 로그인으로 다시 들어가면
  # 무한 루프가 발생할 수 있다.
  # 이를 방지하기 위해 fromlx_failed 플래그와 함께 /login 으로 리다이렉트하여,
  # LoginController 에서 자동 리다이렉트를 멈추고 에러 화면을 표시하도록 위임한다.
  def unsuccessful_login(message)
    if request.format.json?
      return render json: { errors: [message] }, status: :bad_request
    end

    flash[:delegated_message] = message
    redirect_to login_url(fromlx_failed: 1), status: :see_other
  end

  private

  # trusted accounts 에서 canvas/ldap 계열 pseudonym 을 찾되,
  # Pseudonym.authenticate 와 동일한 중복 선택 규칙을 적용한다.
  # - 매칭 pseudonym 들이 정확히 한 사용자에 속하면 그 중 하나를 반환
  # - site_admin pseudonym 이 있으면 우선 반환
  # - 여러 사용자에 걸치면 nil 반환 (로그인 거부)
  #
  # 참고로, 이 메소드는 단일 Shard에서 운영하는 경우를 전제로 Pseudonym 조회.
  def find_trusted_pseudonym(unique_id)
    candidates = Pseudonym.active.by_unique_id(unique_id)
      .where(account_id: @domain_root_account.trusted_account_ids)
      .where("authentication_provider_id IS NULL OR EXISTS (?)",
        AuthenticationProvider.active.where(auth_type: ['canvas', 'ldap'])
          .where("authentication_provider_id=authentication_providers.id"))
      .preload(:user)
      .to_a
    return nil if candidates.empty?

    site_admin = candidates.find { |p| p.account_id == Account.site_admin.id }
    return site_admin if site_admin

    if candidates.map(&:user_id).uniq.length == 1
      candidates.first
    else
      Rails.logger.warn("LearningX login error: ambiguous pseudonym match for '#{unique_id}' across trusted accounts")
      nil
    end
  end

  def decrypt_payload(result_string)
    enc_key_hex = Setting.get('xn_learningx_aes256_key_hex', nil)
    mac_key_hex = Setting.get('xn_learningx_hmac_key_hex', nil)
    if enc_key_hex.blank? || mac_key_hex.blank?
      Rails.logger.warn("LearningX decrypt: keys missing (enc=#{enc_key_hex.present?}, mac=#{mac_key_hex.present?})")
      return nil
    end

    version, iv_b64, ciphertext_b64, mac_b64 = result_string.to_s.split('.', 4)
    unless version == 'v1' && iv_b64.present? && ciphertext_b64.present? && mac_b64.present?
      Rails.logger.warn("LearningX decrypt: format check failed (version=#{version}, parts=#{[iv_b64.present?, ciphertext_b64.present?, mac_b64.present?]})")
      return nil
    end

    enc_key = [enc_key_hex].pack('H*')
    mac_key = [mac_key_hex].pack('H*')
    unless enc_key.bytesize == 32
      Rails.logger.warn("LearningX decrypt: enc_key size=#{enc_key.bytesize}, expected 32")
      return nil
    end
    unless mac_key.bytesize >= 32
      Rails.logger.warn("LearningX decrypt: mac_key size=#{mac_key.bytesize}, expected >=32")
      return nil
    end

    mac_input = [version, iv_b64, ciphertext_b64].join('.')
    expected_mac = OpenSSL::HMAC.digest('sha256', mac_key, mac_input)
    given_mac = Base64.urlsafe_decode64(pad64(mac_b64))
    unless ActiveSupport::SecurityUtils.secure_compare(expected_mac, given_mac)
      Rails.logger.warn("LearningX decrypt: HMAC mismatch (expected=#{expected_mac.unpack1('H*')[0..15]}..., given=#{given_mac.unpack1('H*')[0..15]}...)")
      return nil
    end

    iv = Base64.urlsafe_decode64(pad64(iv_b64))
    ciphertext = Base64.urlsafe_decode64(pad64(ciphertext_b64))

    cipher = OpenSSL::Cipher.new('aes-256-cbc')
    cipher.decrypt
    cipher.key = enc_key
    cipher.iv  = iv
    decrypted = cipher.update(ciphertext) + cipher.final

    JSON.parse(decrypted)
  rescue OpenSSL::Cipher::CipherError, JSON::ParserError, ArgumentError => e
    Rails.logger.warn("LearningX login token verify failed: #{e.message}")
    nil
  end

  def pad64(str)
    str.to_s + ('=' * ((4 - str.to_s.length % 4) % 4))
  end

  def valid_timestamp?(timestamp)
    return false if timestamp.blank?
    (Time.now.to_i - timestamp.to_i).abs <= 30
  end

  def mark_nonce_used_once!(nonce)
    return false if nonce.blank?

    result = Rails.cache.write(
      "lx_login_nonce:#{nonce}", true,
      expires_in: 60.seconds, unless_exist: true
    )

    # Rails.cache.write with unless_exist returns:
    #   true  → 새 nonce, 정상 기록됨
    #   false → 이미 존재하는 nonce (replay)
    #   nil   → Redis 장애 (circuit open 포함)
    #
    # Canvas의 Redis circuit breaker(Canvas::Redis::Client#process)는
    # SET NX 실패 시 :failure → nil 을 반환한다.
    # 보안상 fail-closed 유지: Redis 장애 시에도 로그인을 거부한다.
    if result.nil?
      Rails.logger.error(
        "LearningX login error: Redis unavailable for nonce check " \
        "(circuit may be open). Login denied (fail-closed)."
      )
      return false
    end

    result
  end
end
