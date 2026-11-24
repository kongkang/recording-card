package com.nonpolynomial.btleplug.android.impl;

import android.annotation.SuppressLint;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanFilter.Builder;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.os.Build;
import android.os.ParcelUuid;

import java.util.ArrayList;
import java.util.List;

@SuppressWarnings("unused") // Native code uses this class.
public class Adapter {
    private static volatile Context appContext;

    public static void setAppContext(Context context) {
        appContext = context != null ? context.getApplicationContext() : null;
    }

    static Context getAppContext() {
        return appContext;
    }

    private long handle;
    private final Callback callback = new Callback();

    public Adapter() {}

    @SuppressLint("MissingPermission")
    public String[] getConnectedGattDevices() {
        Context ctx = appContext;
        if (ctx == null) {
            return new String[0];
        }
        try {
            BluetoothManager bluetoothManager =
                    (BluetoothManager) ctx.getSystemService(Context.BLUETOOTH_SERVICE);
            if (bluetoothManager == null) {
                return new String[0];
            }
            List<BluetoothDevice> devices =
                    bluetoothManager.getConnectedDevices(BluetoothProfile.GATT);
            if (devices == null || devices.isEmpty()) {
                return new String[0];
            }
            ArrayList<String> out = new ArrayList<>(devices.size());
            for (BluetoothDevice device : devices) {
                if (device == null) {
                    continue;
                }
                String address = device.getAddress();
                if (address == null || address.isEmpty()) {
                    continue;
                }
                String name = device.getName();
                String cleanName = name != null ? name.replace('\t', ' ') : "";
                out.add(address + "\t" + cleanName);
            }
            return out.toArray(new String[0]);
        } catch (SecurityException | RuntimeException ex) {
            return new String[0];
        }
    }

    @SuppressLint("MissingPermission")
    public void startScan(ScanFilter filter) {
        BluetoothAdapter bluetoothAdapter = BluetoothAdapter.getDefaultAdapter();
        if (bluetoothAdapter == null) {
          throw new NoBluetoothAdapterException();
        }

        ArrayList<android.bluetooth.le.ScanFilter> filters = null;
        String[] uuids = filter.getUuids();
        if (uuids.length > 0) {
            filters = new ArrayList<>();
            for (String uuid : uuids) {
                filters.add(new Builder().setServiceUuid(ParcelUuid.fromString(uuid)).build());
            }
        }
        ScanSettings settings;
        if (Build.VERSION.SDK_INT >= 26) {
            settings = new ScanSettings.Builder()
                    .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                    .setLegacy(false)
                    .build();
        } else {
            settings = new ScanSettings.Builder()
                    .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
                    .build();
        }
        BluetoothLeScanner scanner = bluetoothAdapter.getBluetoothLeScanner();
        if (scanner == null) {
          throw new NoBluetoothAdapterException();
        }
        scanner.startScan(filters, settings, this.callback);
    }

    @SuppressLint("MissingPermission")
    public void stopScan() {
        BluetoothAdapter bluetoothAdapter = BluetoothAdapter.getDefaultAdapter();
        if (bluetoothAdapter != null) {
            BluetoothLeScanner scanner = bluetoothAdapter.getBluetoothLeScanner();
            if (scanner != null) {
                scanner.stopScan(this.callback);
            }
        }
    }

    private native void reportScanResult(ScanResult result);

    public native void onConnectionStateChanged(String address, boolean connected);

    private class Callback extends ScanCallback {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            Adapter.this.reportScanResult(result);
        }
    }
}
