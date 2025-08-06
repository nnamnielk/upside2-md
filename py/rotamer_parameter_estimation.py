import tables as tb
import numpy as np
import tempfile
import subprocess as sp
import os
import theano
import theano.tensor as T
import pickle as cp
import scipy.optimize as opt
import collections

# theano.config.compute_test_value = 'ignore'

n_fix = 3
n_rotpos = 86

n_knot_angular = 15
n_angular = 2 * n_knot_angular
# n_restype = 24
n_restype = 20
n_knot_sc = 12
n_knot_hb = 10
hb_dr = 0.625
sc_dr = 0.7

param_shapes = collections.OrderedDict()
param_shapes['rotamer'] = (n_restype, n_restype, 2 * n_knot_angular + 2 * n_knot_sc)
param_shapes['hbond_coverage'] = (8, n_restype, 2 * n_knot_angular + 2 * n_knot_hb)
param_shapes['hbond_coverage_hydrophobe'] = (12, n_restype, 2 * n_knot_angular + 2 * n_knot_hb)
param_shapes['placement_fixed_point_vector_scalar'] = (n_fix, 7)
param_shapes['placement_fixed_point_vector_only'] = (n_rotpos, 6)
# param_shapes['placement_fixed_scalar']=(n_rotpos,1)

lparam = T.dvector('lparam')
lparam.tag.test_value = np.random.randn(
    n_restype ** 2 * (n_angular + 2 * (n_knot_sc - 3)) + 3 * n_restype * (n_angular + 2 * (n_knot_hb - 3)) + n_fix * 6)

func = lambda expr: (theano.function([lparam], expr,
                                     ), expr)


def unpack_param_maker():
    i = [0]

    def read_param(shape):
        size = np.prod(shape)
        ret = lparam[i[0]:i[0] + size].reshape(shape)
        i[0] += size
        return ret

    def read_symm(n):
        x = read_param((n_restype, n_restype, n))
        return 0.5 * (x + x.transpose((1, 0, 2)))

    def read_cov(n):
        return read_param((8, n_restype, n))

    def read_hyd(n):
        # return read_param((1,n_restype,n))
        return read_param((12, n_restype, n))

    def read_angular_spline(read_func):
        return T.nnet.sigmoid(read_func(n_knot_angular))  # bound on (0,1)

    def read_clamped_spline(read_func, n_knot):
        middle = read_func(n_knot - 3)

        c0 = middle[:, :, 1:2]  # left clamping condition

        cn3 = middle[:, :, -1:]
        cn2 = -0.5 * cn3
        cn1 = cn3  # these two lines ensure right clamp is at 0
        return T.concatenate([c0, middle, cn2, cn1], axis=2)

    angular_spline_sc = read_angular_spline(lambda n: read_param((n_restype, n_restype, n)))

    rot_param = T.concatenate([
        angular_spline_sc, angular_spline_sc.transpose((1, 0, 2)),
        read_clamped_spline(read_symm, n_knot_sc), read_clamped_spline(read_symm, n_knot_sc)],
        axis=2)

    cov_param = T.concatenate([
        read_angular_spline(read_cov), read_angular_spline(read_cov),
        read_clamped_spline(read_cov, n_knot_hb), read_clamped_spline(read_cov, n_knot_hb)],
        axis=2)

    hyd_param = T.concatenate([
        read_angular_spline(read_hyd), read_angular_spline(read_hyd),
        read_clamped_spline(read_hyd, n_knot_hb), read_clamped_spline(read_hyd, n_knot_hb)],
        axis=2)

    hydpl_com = read_param((n_fix, 3))
    hydpl_dir_unnorm = read_param((n_fix, 3))
    hydpl_dir = hydpl_dir_unnorm / T.sqrt((hydpl_dir_unnorm ** 2).sum(axis=-1, keepdims=True))
    hydpl_param = T.concatenate([hydpl_com, hydpl_dir, T.zeros((n_fix, 1))], axis=-1)

    rotpos_com = read_param((n_rotpos, 3))
    rotpos_dir_unnorm = read_param((n_rotpos, 3))
    rotpos_dir = rotpos_dir_unnorm / T.sqrt((rotpos_dir_unnorm ** 2).sum(axis=-1, keepdims=True))
    rotpos_param = T.concatenate([rotpos_com, rotpos_dir], axis=-1)

    rotscalar_param = read_param((n_rotpos, 1))

    n_param = int(i[0])

    return func(rot_param), func(cov_param), func(hyd_param), func(hydpl_param), func(rotpos_param), func(
        rotscalar_param), n_param


(unpack_rot, unpack_rot_expr), (unpack_cov, unpack_cov_expr), \
    (unpack_hyd, unpack_hyd_expr), (unpack_hydpl, unpack_hydpl_expr), \
    (unpack_rotpos, unpack_rotpos_expr), \
    (unpack_rotscalar, unpack_rotscalar_expr), \
    n_param = unpack_param_maker()
unpack_params_expr = unpack_rot_expr, unpack_cov_expr, unpack_hyd_expr, unpack_hydpl_expr, unpack_rotpos_expr, unpack_rotscalar_expr


def unpack_params(state):
    return unpack_rot(state), unpack_cov(state), unpack_hyd(state), unpack_hydpl(state), unpack_rotpos(
        state), unpack_rotscalar(state)


def pack_param_helper_maker():
    loose_cov_var = T.dtensor3('loose_cov')
    loose_rot_var = T.dtensor3('loose_rot')
    loose_hyd_var = T.dtensor3('loose_hyd')
    loose_hydpl_var = T.dmatrix('loose_hydpl')
    loose_rotpos_var = T.dmatrix('loose_rotpos')
    loose_rotscalar_var = T.dmatrix('loose_rotscalar')

    discrep_expr = (
            T.sum((unpack_rot_expr - loose_rot_var) ** 2) +
            T.sum((unpack_cov_expr - loose_cov_var) ** 2) +
            T.sum((unpack_hyd_expr - loose_hyd_var) ** 2) +
            T.sum((unpack_hydpl_expr - loose_hydpl_var) ** 2) +
            T.sum((unpack_rotpos_expr - loose_rotpos_var) ** 2) +
            T.sum((unpack_rotscalar_expr - loose_rotscalar_var) ** 2))
    v = [lparam, loose_rot_var, loose_cov_var, loose_hyd_var, loose_hydpl_var, loose_rotpos_var, loose_rotscalar_var]
    discrep = theano.function(v, discrep_expr)
    d_discrep = theano.function(v, T.grad(discrep_expr, lparam))
    return discrep, d_discrep

discrep, d_discrep = pack_param_helper_maker()

def pack_param(*args):
    # solve the resulting equations so I don't have to work out the formula
    results = opt.minimize(
        (lambda x: discrep(x, *args)),
        0.5 + np.zeros(n_param),
        method='L-BFGS-B', options=dict(maxiter=10000),
        jac=(lambda x: d_discrep(x, *args)))
    # print('required %i evaluations' % (results.nfev, ))

    if not (discrep(results.x, *args) < 1e-4):
        raise ValueError('Failed to converge')

    return results.x


def quadspline_energy(params, n_knots):
    # assert sum(n_knots) == params.shape[-1]
    dp1 = params[:, :, :sum(n_knots[:1])]
    dp2 = params[:, :, sum(n_knots[:1]):sum(n_knots[:2])]
    uni = params[:, :, sum(n_knots[:2]):sum(n_knots[:3])]
    direc = params[:, :, sum(n_knots[:3]):]

    ev = lambda sp: (1. / 6.) * sp[:, :, :-2] + (2. / 3.) * sp[:, :, 1:-1] + (1. / 6.) * sp[:, :, 2:]

    return ev(uni)[:, :, :, None, None] + ev(dp1)[:, :, None, :, None] * ev(dp2)[:, :, None, None, :] * ev(direc)[
        :, :, :, None, None]


def multimin(a, axes):
    for ax in axes:
        a = a.min(axis=ax, keepdims=1)
    return a


def quadspline_prob(energies):
    # assert len(energies.shape) == 5
    r_weights = T.arange(1, energies.shape[2] + 1) ** 2
    prob_unnorm = T.exp(multimin(energies, (-3, -2, -1)) - energies) * r_weights[None, None, :, None, None]
    return prob_unnorm * (1. / prob_unnorm.sum(axis=(-3, -2, -1), keepdims=1))


def quadspline_neglognorm(energies):
    # assert len(energies.shape) == 5
    energies_with_vol = energies - 2. * T.log(1 + T.arange(energies.shape[2]))[None, None, :, None, None]
    emin = multimin(energies_with_vol, (-3, -2, -1))  # numerical stability
    # note that I use a mean instead of sum to make it easier to compare different grid sizes
    return -T.log(T.exp(emin - energies).mean(axis=(-3, -2, -1))) + emin[:, :, 0, 0, 0]


def quadspline_expectation(prob_norm, observable):
    return (prob_norm * observable).sum(axis=(-3, -2, -1))


def bind_param_and_evaluate(pos_fix_free, node_names, param_matrices):
    energy = np.zeros(2)
    deriv = [np.zeros((2,) + pm.shape) for pm in param_matrices]

    for pos, fix, free in pos_fix_free:
        for nm, pm in zip(node_names, param_matrices):
            fix.set_param(pm, nm)
            free.set_param(pm, nm)

        energy[0] += fix.energy(pos)
        energy[1] += free.energy(pos)

        if np.isnan(energy[0]): raise RuntimeError('NaN energy for %s %s' % (fix,
                                                                             [np.any(np.isnan(x)) for x in
                                                                              param_matrices]))
        if np.isnan(energy[1]): raise RuntimeError('NaN energy for %s %s' % (free,
                                                                             [x for x in param_matrices]))

        this_deriv = [(fix.get_param_deriv(d[0].shape, nm),
                       free.get_param_deriv(d[0].shape, nm)) for d, nm in zip(deriv, node_names)]

        for d, (d0, d1) in zip(deriv, this_deriv):
            d[0] += d0
            d[1] += d1

    return energy, deriv


class UpsideEnergyGap(theano.Op):
    def __init__(self, protein_data, node_names):
        self.protein_data = [None, None]
        self.change_protein_data(protein_data)  # (total_n_res, pos_fix_free)
        self.node_names = node_names  # should be OrderedDict

    def make_node(self, *param):
        assert len(param) == len(self.node_names)
        return theano.Apply(self, [T.as_tensor_variable(x) for x in param],
                            [T.dvector()])

    def perform(self, node, inputs_storage, output_storage):
        total_n_res, pos_fix_free = self.protein_data
        energy, deriv = bind_param_and_evaluate(pos_fix_free, list(self.node_names), inputs_storage)
        output_storage[0][0] = (energy / total_n_res).astype('f8')

    def grad(self, inputs, output_gradients):
        grad_func = UpsideEnergyGapGrad(self.protein_data, self.node_names)  # grad will have linked data
        gf = grad_func(*inputs)
        if len(inputs) == 1: gf = [gf]  # single inputs cause problems
        return [T.tensordot(output_gradients[0], x, axes=(0, 0)) for x in gf]

    def change_protein_data(self, new_protein_data):
        self.protein_data[0] = 1 * new_protein_data[0]
        self.protein_data[1] = list(new_protein_data[1])


class UpsideEnergyGapGrad(theano.Op):
    def __init__(self, protein_data, node_names):
        self.protein_data = protein_data
        self.node_names = node_names

    def make_node(self, *param):
        assert len(param) == len(self.node_names)
        size_conv = {1: T.dmatrix, 2: T.dtensor3, 3: T.dtensor4}
        return theano.Apply(self,
                            [T.as_tensor_variable(p) for p in param],
                            [size_conv[len(sz)]() for nn, sz in self.node_names.items()])

    def perform(self, node, inputs_storage, output_storage):
        total_n_res, pos_fix_free = self.protein_data
        energy, deriv = bind_param_and_evaluate(pos_fix_free, list(self.node_names), inputs_storage)
        if np.isnan(np.sum([x.sum() for x in deriv])):
            print([x.sum() for x in inputs_storage])
            print([x[0, 0] for x in inputs_storage])
            print([np.isnan(x.sum()) for x in deriv])
            print(energy)
            raise RuntimeError()

        for i in range(len(output_storage)):
            output_storage[i][0] = (deriv[i] * (1. / total_n_res)).astype('f8')


def sgd_sweep(state, mom, mu, eps, minibatches, change_batch_function, d_obj, nesterov=True):
    for mb in minibatches:
        change_batch_function(mb)
        # note that the momentum update happens *before* the state update
        mom = mu * mom - eps * d_obj(state + mu * mom if nesterov else state)
        state = state + mom
    return state, mom


def rmsprop_sweep(state, mom, minibatches, change_batch_function, d_obj, lr=0.001, rho=0.9, epsilon=1e-6):
    for mb in minibatches:
        change_batch_function(mb)
        grad = d_obj(state)
        mom = rho * mom + (1 - rho) * grad ** 2
        state = state - lr * grad / np.sqrt(mom + epsilon)
    return state, mom


# handle a mix of scalars and lists
def read_comp(x, i):
    try:
        return x[i]
    except:
        return x  # scalar case


class AdamSolver(object):
    ''' See Adam optimization paper (Kingma and Ba, 2015) for details. Beta2 is reduced by
    default to handle the shorter training expected on protein problems.  alpha is roughly
    the largest possible step size.'''

    # def __init__(self, n_comp, alpha=1e-2, beta1=0.9, beta2=0.98, epsilon=1e-6):
    def __init__(self, n_comp, alpha=1e-2, beta1=0.8, beta2=0.96, epsilon=1e-6):
        self.n_comp = n_comp

        self.alpha = alpha
        self.beta1 = beta1
        self.beta2 = beta2
        self.epsilon = epsilon

        self.step_num = 0
        self.grad1 = [0. for i in range(n_comp)]  # accumulator of gradient
        self.grad2 = [0. for i in range(n_comp)]  # accumulator of gradient**2

    def update_for_d_obj(self, ):
        return [0. for x in self.grad1]  # This method is used in Nesterov SGD, not Adam

    def update_step(self, grad):
        r = read_comp
        self.step_num += 1
        t = self.step_num

        u = [None] * len(self.grad1)
        for i, g in enumerate(grad):
            b = r(self.beta1, i);
            self.grad1[i] = b * self.grad1[i] + (1. - b) * g;
            grad1corr = self.grad1[i] / (1 - b ** t)
            b = r(self.beta2, i);
            self.grad2[i] = b * self.grad2[i] + (1. - b) * g ** 2;
            grad2corr = self.grad2[i] / (1 - b ** t)
            u[i] = -r(self.alpha, i) * grad1corr / (np.sqrt(grad2corr) + r(self.epsilon, i))

        return u

    def log_state(self, direc):
        with open(os.path.join(direc, 'solver_state.pkl'), 'wb') as f:
            cp.dump(dict(step_num=self.step_num, grad1=self.grad1, grad2=self.grad2, solver=str(self)), f, -1)

    def __repr__(self):
        return 'AdamSolver(%i, alpha=%r, beta1=%r, beta2=%r, epsilon=%r)' % (
            self.n_comp, self.alpha, self.beta1, self.beta2, self.epsilon)

    def __str__(self):
        return 'AdamSolver(%i, alpha=%s, beta1=%s, beta2=%s, epsilon=%s)' % (
            self.n_comp, self.alpha, self.beta1, self.beta2, self.epsilon)


class SGD_Solver(object):
    def __init__(self, n_comp, mu=0.9, learning_rate=0.1, nesterov=True):
        self.n_comp = n_comp

        self.mu = mu
        self.learning_rate = learning_rate
        self.nesterov = nesterov

        self.momentum = [0. for i in range(n_comp)]

    def update_for_d_obj(self, ):
        if self.nesterov:
            return [read_comp(self.mu, i) * self.momentum[i] for i in range(self.n_comp)]
        else:
            return [0. for i in range(self.n_comp)]

    def update_step(self, grad):
        self.momentum = [read_comp(self.mu, i) * self.momentum[i] - read_comp(self.learning_rate, i) * grad[i]
                         for i in range(self.n_comp)]
        return [1. * x for x in self.momentum]  # make sure the user doesn't smash the momentum


class UpsideTrajEnergy(theano.Op):
    def __init__(self, param_shapes_dict):
        self.engine_traj = [None, None]
        self.param_shapes_dict = collections.OrderedDict(param_shapes_dict)

    def make_node(self, *param):
        assert len(param) == len(self.param_shapes_dict)
        return theano.Apply(self, [T.as_tensor_variable(x) for x in param], [T.dvector()])

    def perform(self, node, inputs_storage, output_storage):
        engine, traj = self.engine_traj

        energy = np.zeros(traj.shape[0])
        for nm, pm in zip(self.param_shapes_dict, inputs_storage):
            engine.set_param(pm, nm)

        for nf, x in enumerate(traj):
            energy[nf] = engine.energy(x)

        output_storage[0][0] = energy

    def grad(self, inputs, output_gradients):
        grad_func = UpsideTrajEnergyGrad(self.engine_traj, self.param_shapes_dict)  # grad will have linked data
        return grad_func(output_gradients[0], *inputs)

    def change_protein_data(self, engine, traj):
        self.engine_traj[0] = engine
        self.engine_traj[1] = traj


class UpsideTrajEnergyGrad(theano.Op):
    def __init__(self, engine_traj, param_shapes_dict):
        self.engine_traj = engine_traj
        self.param_shapes_dict = param_shapes_dict

    def make_node(self, output_sens, *param):
        assert len(param) == len(self.param_shapes_dict)
        size_conv = {0: T.dscalar, 1: T.dvector, 2: T.dmatrix, 3: T.dtensor3}
        return theano.Apply(self,
                            [T.as_tensor_variable(p) for p in (output_sens,) + param],
                            [size_conv[len(sz)]() for nn, sz in self.param_shapes_dict.items()])

    def perform(self, node, inputs_storage, output_storage):
        engine, traj = self.engine_traj

        for i, (nm, sp) in enumerate(self.param_shapes_dict.items()):
            assert inputs_storage[1 + i].shape == sp

        for nm, pm in zip(self.param_shapes_dict, inputs_storage[1:]):
            engine.set_param(pm, nm)

        deriv = [np.zeros(shape) for nm, shape in self.param_shapes_dict.items()]
        sens = inputs_storage[0]
        for nf, x in enumerate(traj):
            engine.energy(x)  # ensure derivatives are correct
            s = sens[nf]

            for nm, d in zip(self.param_shapes_dict, deriv):
                d[slice(None, None, None) if len(d.shape) else ()] += s * engine.get_param_deriv(d.shape, nm)

        for i in range(len(output_storage)):
            output_storage[i][0] = deriv[i]


def low_rank_approximation(m, rank):
    m = m.astype('f8')
    u, s, vh = np.linalg.svd(m, full_matrices=True)
    u[:, rank:] = 0.
    s[rank:] = 0.
    vh[rank:, :] = 0.
    m_approx = np.dot(u, s[:, None] * vh)
    return m_approx