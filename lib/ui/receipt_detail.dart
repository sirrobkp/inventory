import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../data/app_state.dart';
import '../data/models.dart';
import 'icons.dart';
import 'returns_ui.dart';
import 'theme.dart';
import 'widgets.dart';

class ReceiptDetail extends StatelessWidget {
  const ReceiptDetail(this.sale);
  final Sale sale;
  @override
  Widget build(BuildContext context) {
    final s = context.read<AppState>();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Receipt #${sale.number}', style: t(18, w: FontWeight.w800)), Badge2(sale.uploaded ? 'Accepted' : sale.uploadStatus == 'failed' ? 'Rejected' : 'Queued', color: sale.uploaded ? K.lime : sale.uploadStatus == 'failed' ? K.danger : K.amber)]),
      const SizedBox(height: 4),
      Text('${DateFormat('d MMM yyyy HH:mm').format(sale.createdAt)}  -  ${sale.paymentType}', style: t(11, w: FontWeight.w500, c: K.muted)),
      const SizedBox(height: 14),
      for (final i in sale.items) Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Text('${fmtQ(i.qty)} x ${i.name}', style: t(12, w: FontWeight.w500))), Text(num0(i.amount), style: t(12))])),
      const Divider(color: Color(0x1AFFFFFF)),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Net ${num0(sale.totalExcl)}  -  VAT ${num0(sale.totalVat)}', style: t(11, w: FontWeight.w500, c: K.muted)), Text(money(sale.totalIncl), style: t(15, w: FontWeight.w800))]),
      const SizedBox(height: 10),
      Text('Verification: ${sale.rctvnum}', style: mono(10, c: K.muted)),
      if (sale.ackMsg != null) Text('TRA: ${sale.ackCode} ${sale.ackMsg}', style: mono(10, c: K.muted)),
      if (sale.lastError != null && !sale.uploaded) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Last error: ${sale.lastError}', style: t(11, w: FontWeight.w600, c: K.danger))),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: LimeButton('Reprint', icon: Ic.printer, onTap: () async => toast(context, await s.printReceipt(sale)))),
        const SizedBox(width: 10),
        Expanded(child: LimeButton('PDF', icon: Ic.pdf, outline: true, onTap: () => s.printer.sharePdf(context, sale, s.cfg))),
      ]),
      const SizedBox(height: 10),
      LimeButton('Return items (credit note)', icon: Ic.refresh, outline: true, onTap: () => showSheet(context, ReturnSheet(sale: sale))),
    ]);
  }
}

String fmtQ(double q) => q == q.roundToDouble() ? q.toStringAsFixed(0) : q.toString();
