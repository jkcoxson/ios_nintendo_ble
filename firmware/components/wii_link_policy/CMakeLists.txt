idf_component_register(REQUIRES bt)

# ESP-IDF 5.5.4 otherwise moves Classic HID links into 33.75 ms sniff mode
# after ~30 seconds, even with continuous Wii MotionPlus/IR input. This bridge
# uses Classic exclusively for game controllers: keep those links active while
# connected. Preserve role switching; BLE connection parameters are independent.
# Override the stack's supported compile-time default without modifying the SDK
# or calling its private power-management functions from a Rust task.
idf_component_get_property(wii_bt_target bt COMPONENT_LIB)
target_compile_definitions(${wii_bt_target} PRIVATE
    BTA_DM_LINK_POLICY_SETTINGS=HCI_ENABLE_MASTER_SLAVE_SWITCH)

# Compile patched copies; the pinned SDK checkout stays untouched. Reconfigure
# when this script changes, and reject SDK drift instead of silently skipping a fix.
idf_component_get_property(wii_bt_dir bt COMPONENT_DIR)
idf_build_get_property(wii_python PYTHON)
set(wii_hid_generated "${CMAKE_CURRENT_BINARY_DIR}/hid_fixes")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_LIST_DIR}/patch_hid.py")
execute_process(COMMAND "${wii_python}" "${CMAKE_CURRENT_LIST_DIR}/patch_hid.py"
    "${wii_bt_dir}" "${wii_hid_generated}" RESULT_VARIABLE wii_patch_result)
if(NOT wii_patch_result EQUAL 0)
    message(FATAL_ERROR "Pinned ESP-IDF HID patches failed")
endif()
get_target_property(wii_bt_sources ${wii_bt_target} SOURCES)
foreach(wii_source IN LISTS wii_bt_sources)
    if(wii_source MATCHES "(bta_hh_act|btc_hh)\\.c$")
        list(REMOVE_ITEM wii_bt_sources "${wii_source}")
    endif()
endforeach()
set_property(TARGET ${wii_bt_target} PROPERTY SOURCES ${wii_bt_sources}
    "${wii_hid_generated}/bta_hh_act.c" "${wii_hid_generated}/btc_hh.c")
