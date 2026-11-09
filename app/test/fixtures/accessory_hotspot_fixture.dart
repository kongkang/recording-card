import 'package:recording_card/core/device/card_gateway.dart';
import 'package:recording_card/services/runtime/accessory_hotspot_session.dart';

/// Explicit test injection: never changes the production platform/channel path.
AccessoryHotspotSession fixtureHotspot(CardGateway gateway) =>
    AccessoryHotspotSession(
      gateway,
      isIos: () => true,
      join: () async {},
      closePhoneConfiguration: () async {},
      probe: (_, _) async => true,
    );
