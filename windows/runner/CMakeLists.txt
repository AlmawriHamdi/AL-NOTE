add_executable(${BINARY_NAME} WIN32 main.cpp)
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
