task :travis do
  ["rspec", "cucumber"].each do |cmd|
    puts "Starting to run #{cmd}..."
    system("export DISPLAY=:99.0 && bundle exec rake knapsack:#{cmd}")
    raise "#{cmd} failed!" unless $?.exitstatus == 0
  end
end
