cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(atk_native_zephyr_periodic)

# Reuse the Task 1 probe so native and virtualized runs use the same absolute
# deadline and cycle-counter measurement algorithm.
target_sources(app PRIVATE
  ${CMAKE_CURRENT_LIST_DIR}/../zephyr-periodic/src/main.c
  src/native_boot.c
)
target_compile_definitions(app PRIVATE RT_SAMPLE_COUNT=300 RT_START_DELAY_MS=0)
