class TraResult {
  TraResult({required this.ok, this.code = '', this.msg = '', this.retryLater = false, this.receiptNo = '', this.verifyCode = '', this.verifyUrl = ''});
  final bool ok;
  final String code, msg;
  final bool retryLater; // auth/network: leave in queue, try again
  final String receiptNo, verifyCode, verifyUrl; // filled by supplier APIs
}
