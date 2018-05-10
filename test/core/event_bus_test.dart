// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_pad.event_bus_test;

import 'dart:async';

import 'package:dart_pad/core/event_bus.dart';
import 'package:test/test.dart';

main() => defineTests();

void defineTests() {
  group('event_bus', () {
    test('fire one event', () {
      EventBus bus = new EventBus();
      Future<List> f = bus.onEvent('file-save').toList();
      _fireEvents(bus);
      bus.close();
      return f.then((List l) {
        expect(l.length, 1);
      });
    });

    test('fire two events', () {
      EventBus bus = new EventBus();
      Future<List> f = bus.onEvent('file-modified').toList();
      _fireEvents(bus);
      bus.close();
      return f.then((List l) {
        expect(l.length, 2);
        expect(l[0].args['file'], 'a');
        expect(l[1].args['file'], 'b');
      });
    });

    test('receive all events', () {
      EventBus bus = new EventBus();
      Future<List> f = bus.onEvent().toList();
      _fireEvents(bus);
      bus.close();
      return f.then((List l) {
        expect(l.length, 3);
      });
    });
  });
}

void _fireEvents(EventBus bus) {
  bus.addEvent(new BusEvent('file-save', {'file': 'a'}));
  bus.addEvent(new BusEvent('file-modified', {'file': 'a'}));
  bus.addEvent(new BusEvent('file-modified', {'file': 'b'}));
}
