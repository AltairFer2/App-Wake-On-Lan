import 'dart:io';

import 'package:altair_wake/core/network/ip_classification.dart';
import 'package:altair_wake/core/network/network_validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PortValidator', () {
    test('acepta el rango 1–65535', () {
      for (final port in ['1', '9', '7', '65535', ' 40000 ']) {
        expect(PortValidator.validate(port), isNull, reason: port);
      }
    });

    test('rechaza límites y valores no numéricos', () {
      for (final port in ['0', '65536', '-1', 'abc', '9.5', '']) {
        expect(PortValidator.validate(port), isNotNull, reason: port);
      }
    });

    test('vacío es válido cuando el campo es opcional', () {
      expect(PortValidator.validate('', required: false), isNull);
      expect(PortValidator.validate(null, required: false), isNull);
      expect(PortValidator.validate('0', required: false), isNotNull);
    });
  });

  group('HostValidator.classify', () {
    test('distingue IPv4, IPv6 y nombres DNS', () {
      expect(HostValidator.classify('192.168.100.20'), HostKind.ipv4);
      expect(HostValidator.classify('2806:2f0::1'), HostKind.ipv6);
      expect(HostValidator.classify('pc.example.net'), HostKind.hostname);
      expect(HostValidator.classify('router'), HostKind.hostname);
    });

    test('rechaza entradas inválidas', () {
      for (final input in [
        '',
        '192.168.100.256',
        '1.2.3',
        '-bad.example.com',
        'bad-.example.com',
        'a..b',
        'espacio aquí.com',
        '${'a' * 64}.com',
      ]) {
        expect(HostValidator.classify(input), isNull, reason: input);
      }
    });
  });

  group('HostValidator.validateIpv4', () {
    test('opcional por defecto', () {
      expect(HostValidator.validateIpv4(''), isNull);
      expect(HostValidator.validateIpv4('', required: true), isNotNull);
    });

    test('rechaza IPv6 y texto', () {
      expect(HostValidator.validateIpv4('::1'), isNotNull);
      expect(HostValidator.validateIpv4('host'), isNotNull);
      expect(HostValidator.validateIpv4('255.255.255.255'), isNull);
    });
  });

  group('HostValidator.validateGlobalIpv6', () {
    test('acepta solo unicast global', () {
      expect(HostValidator.validateGlobalIpv6('2806:2f0:1234::10'), isNull);
      expect(HostValidator.validateGlobalIpv6('fe80::1'), isNotNull);
      expect(HostValidator.validateGlobalIpv6('fd00::1'), isNotNull);
      expect(HostValidator.validateGlobalIpv6('::1'), isNotNull);
      expect(HostValidator.validateGlobalIpv6('192.168.1.1'), isNotNull);
    });
  });

  group('HostValidator.validateRemoteHost', () {
    test('el modo IPv4 acepta IPv4 o DNS, no IPv6', () {
      expect(
        HostValidator.validateRemoteHost('203.0.113.7', family: HostKind.ipv4),
        isNull,
      );
      expect(
        HostValidator.validateRemoteHost('casa.example.net', family: HostKind.ipv4),
        isNull,
      );
      expect(
        HostValidator.validateRemoteHost('2806::1', family: HostKind.ipv4),
        isNotNull,
      );
    });

    test('el modo IPv6 exige IPv6 global o DNS', () {
      expect(
        HostValidator.validateRemoteHost('2806:2f0::1', family: HostKind.ipv6),
        isNull,
      );
      expect(
        HostValidator.validateRemoteHost('fe80::1', family: HostKind.ipv6),
        isNotNull,
      );
      expect(
        HostValidator.validateRemoteHost('203.0.113.7', family: HostKind.ipv6),
        isNotNull,
      );
    });
  });

  group('IpClassification', () {
    AddressScope scope(String ip) =>
        IpClassification.scopeOf(InternetAddress(ip));

    test('clasifica IPv4', () {
      expect(scope('10.85.101.80'), AddressScope.private);
      expect(scope('172.16.0.1'), AddressScope.private);
      expect(scope('172.32.0.1'), AddressScope.public);
      expect(scope('192.168.100.1'), AddressScope.private);
      expect(scope('100.64.0.1'), AddressScope.carrierGradeNat);
      expect(scope('100.127.255.254'), AddressScope.carrierGradeNat);
      expect(scope('100.128.0.1'), AddressScope.public);
      expect(scope('127.0.0.1'), AddressScope.nonRoutable);
      expect(scope('169.254.1.1'), AddressScope.nonRoutable);
      expect(scope('255.255.255.255'), AddressScope.nonRoutable);
      expect(scope('8.8.8.8'), AddressScope.public);
    });

    test('clasifica IPv6', () {
      expect(scope('2806:2f0::1'), AddressScope.public);
      expect(scope('fd12::1'), AddressScope.private);
      expect(scope('fe80::1'), AddressScope.nonRoutable);
      expect(scope('ff02::1'), AddressScope.nonRoutable);
      expect(scope('::1'), AddressScope.nonRoutable);
    });
  });
}
