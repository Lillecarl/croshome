function cc
    pushd ~/Code/chatbot/
    claude --model haiku "$argv"
    popd
end
