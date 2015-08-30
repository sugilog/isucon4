worker_processes 10
preload_app true

root = File.expand_path("../", __FILE__)
stderr_path File.join(root, "log", "unicorn.log")
stdout_path File.join(root, "log", "unicorn.log")
