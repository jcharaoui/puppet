# frozen_string_literal: true
# Provides stepping with given interval over elements in an iterable and optionally runs a
# [lambda](https://puppet.com/docs/puppet/latest/lang_lambdas.html) for each
# element.
#
# This function takes two to three arguments:
#
# 1. An 'Iterable' that the function will iterate over.
# 2. An `Integer` step factor. This must be a positive integer.
# 3. An optional lambda, which the function calls for each element in the interval. It must
#    request one parameter.
#
# @example Using the `step` function
#
# ```puppet
# $data.step(<n>) |$parameter| { <PUPPET CODE BLOCK> }
# ```
#
# or
#
# ```puppet
# $stepped_data = $data.step(<n>)
# ```
#
# or
#
# ```puppet
# step($data, <n>) |$parameter| { <PUPPET CODE BLOCK> }
# ```
#
# or
#
# ```puppet
# $stepped_data = step($data, <n>)
# ```
#
# When no block is given, Puppet returns an `Iterable` that yields the first element and every nth successor
# element, from its first argument. This allows functions on iterables to be chained.
# When a block is given, Puppet iterates and calls the block with the first element and then with
# every nth successor element. It then returns `undef`.
#
# @example Using the `step` function with an array, a step factor, and a one-parameter block
#
# ```puppet
# # For the array $data, call a block with the first element and then with each 3rd successor element
# $data = [1,2,3,4,5,6,7,8]
# $data.step(3) |$item| {
#  notice($item)
# }
# # Puppet notices the values '1', '4', '7'.
# ```

# When no block is given, Puppet returns a new `Iterable` which allows it to be directly chained into
# another function that takes an `Iterable` as an argument.
#
# @example Using the `step` function chained with a `map` function.
#
# ```puppet
# # For the array $data, return an array, set to the first element and each 5th successor element, in reverse
# # order multiplied by 10
# $data = Integer[0,20]
# $transformed_data = $data.step(5).map |$item| { $item * 10 }
# $transformed_data contains [0,50,100,150,200]
# ```
#
# @example The same example using `step` function chained with a `map` in alternative syntax
#
# ```puppet
# # For the array $data, return an array, set to the first and each 5th
# # successor, in reverse order, multiplied by 10
# $data = Integer[0,20]
# $transformed_data = map(step($data, 5)) |$item| { $item * 10 }
# $transformed_data contains [0,50,100,150,200]
# ```
#
# @since 4.4.0
#
Puppet::Functions.create_function(:step) do
  dispatch :step do
    param 'Iterable', :iterable
    param 'Integer[1]', :step
  end

  dispatch :step_block do
    param 'Iterable', :iterable
    param 'Integer[1]', :step
    block_param 'Callable[1,1]', :block
  end

  def step(iterable, step)
    # produces an Iterable
    Puppet::Pops::Types::Iterable.asserted_iterable(self, iterable, true).step(step)
  end

  def step_block(iterable, step, &block)
    Puppet::Pops::Types::Iterable.asserted_iterable(self, iterable).step(step, &block)
    nil
  end
end
