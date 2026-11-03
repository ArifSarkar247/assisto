// invoices — API calls (core/invoice_views.py). Money is integer poisha.
import '../../../api.dart';

extension InvoiceApi on ApiClient {
  String _b(String path, int? businessId) =>
      businessId == null ? path : '$path${path.contains('?') ? '&' : '?'}business=$businessId';

  Future<Map<String, dynamic>> invoiceSettings({int? businessId}) =>
      getJson(_b('/business/invoice/settings', businessId));

  Future<Map<String, dynamic>> invoiceSettingsSave(Map<String, dynamic> body,
          {int? businessId}) =>
      postJson(_b('/business/invoice/settings', businessId), body);

  Future<Map<String, dynamic>> saleInvoice(int saleId, {int? businessId}) =>
      getJson(_b('/business/sales/$saleId/invoice', businessId));

  /// invdesign: paper-only facts of a POS sale (template, table/token/...,
  /// per-line serial/IMEI + warranty months). Returns the updated invoice.
  Future<Map<String, dynamic>> saleInvoiceDetails(int saleId, Map<String, dynamic> body,
          {int? businessId}) =>
      postJson(_b('/business/sales/$saleId/invoice/details', businessId), body);

  Future<Map<String, dynamic>> invoiceSales({int? businessId}) =>
      getJson(_b('/business/invoices/sales', businessId));

  Future<Map<String, dynamic>> manualInvoices({int? businessId}) =>
      getJson(_b('/business/invoices', businessId));

  Future<Map<String, dynamic>> manualInvoice(int id, {int? businessId}) =>
      getJson(_b('/business/invoices/$id', businessId));

  Future<Map<String, dynamic>> manualInvoiceCreate(Map<String, dynamic> body,
          {int? businessId}) =>
      postJson(_b('/business/invoices', businessId), body);

  Future<Map<String, dynamic>> manualInvoiceCancel(int id, String reason,
          {int? businessId}) =>
      postJson(_b('/business/invoices/$id/cancel', businessId), {'reason': reason});
}
