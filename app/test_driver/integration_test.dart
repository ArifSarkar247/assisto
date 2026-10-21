// Host-side driver for the reality audit. Writes the app's reported flow
// results even when some flows failed (writeResponseOnFailure) so CI always
// gets the JSON; screenshots are pulled from the device separately.
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      writeResponseOnFailure: true,
      responseDataCallback: (data) async {
        final dir = Directory(Platform.environment['REALITY_OUT'] ?? 'reality_out');
        await dir.create(recursive: true);
        await writeResponseData(data,
            testOutputFilename: 'driver_response', destinationDirectory: dir.path);
      },
    );
