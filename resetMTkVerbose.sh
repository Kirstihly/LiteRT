adb wait-for-device
adb root
adb remount
 
adb root
 
adb shell setprop debug.mtk_tflite.vlog false
 
adb shell setprop debug.nn.vlog 0
adb shell setprop debug.neuropilot.vlog false
 
adb root
 
adb shell setprop persist.vendor.apuware.debug.utilslog 0
adb shell setprop persist.vendor.apuware.debug.xrplog 0
adb shell setprop persist.vendor.apuware.debug.apusyslog 0
 
adb root
 
adb shell setprop debug.neuron.adapter.AdapterSetDebugLevel
 
adb shell setprop debug.neuron.runtime.Verbose false
adb shell setprop debug.neuron.runtime.DumpVerbose false
 
adb shell stop neuralnetworks_hal_mtk_neuron_service
adb shell stop neuralnetworks_hal_service_mtk_neuron
adb shell stop neuralnetworks_hal_service_shim_mtk

sleep 2

adb shell start neuralnetworks_hal_mtk_neuron_service
adb shell start neuralnetworks_hal_service_mtk_neuron
adb shell start neuralnetworks_hal_service_shim_mtk

echo "Check properties"
adb shell getprop debug.mtk_tflite.vlog
adb shell getprop debug.nn.vlog
adb shell getprop debug.neuropilot.vlog
adb shell getprop persist.vendor.apuware.debug.utilslog
adb shell getprop persist.vendor.apuware.debug.xrplog
adb shell getprop persist.vendor.apuware.debug.apusyslog
adb shell getprop debug.neuron.adapter.AdapterSetDebugLevel
adb shell getprop debug.neuron.runtime.Verbose
adb shell getprop debug.neuron.runtime.DumpVerbose